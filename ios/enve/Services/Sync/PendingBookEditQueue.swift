import Foundation
import Logging
import Network

enum PendingBookEditDisposition {
    case delivered
    /// The provider or its book is not available right now; the edit stays queued untouched.
    case unavailable
    /// The book or the capability no longer exists, so the edit can never be delivered.
    case obsolete
}

enum PendingBookEditStatus: Equatable {
    case sending
    case waiting
    case retrying(message: String)
    case needsSignIn
    case rejected(message: String)
}

@MainActor
protocol PendingBookEditTransporting: AnyObject {
    func send(_ edit: PendingBookEdit, isCurrent: @escaping @MainActor () -> Bool) async throws -> PendingBookEditDisposition
}

@MainActor
final class ProviderPendingBookEditTransport: PendingBookEditTransporting {
    private let providerResolver: any LibraryProviderResolving
    private let bookLookup: (String) async -> Book?
    private let serialQueue: PerBookSerialQueue

    init(
        providerResolver: any LibraryProviderResolving,
        bookLookup: @escaping (String) async -> Book?,
        serialQueue: PerBookSerialQueue
    ) {
        self.providerResolver = providerResolver
        self.bookLookup = bookLookup
        self.serialQueue = serialQueue
    }

    func send(_ edit: PendingBookEdit, isCurrent: @escaping @MainActor () -> Bool) async throws -> PendingBookEditDisposition {
        guard let book = await bookLookup(edit.key.uniqueId) else { return .unavailable }

        var result: Result<PendingBookEditDisposition, any Error> = .success(.unavailable)
        await serialQueue.enqueue(bookId: book.stableId) {
            guard isCurrent(),
                let provider = self.providerResolver.provider(for: edit.key.connectionId),
                ServerMirrorFingerprint.accountKey(for: provider.connection) == edit.key.accountKey
            else { return }
            do {
                switch edit.value {
                case .rating(let rating):
                    guard let ratings = provider as? any PersonalRatingProvider, ratings.supportsPersonalRating else {
                        result = .success(.obsolete)
                        return
                    }
                    try await ratings.updatePersonalRating(for: book, rating: rating)
                case .readStatus(let rawStatus):
                    guard let statuses = provider as? any ReadStatusEditingProvider else {
                        result = .success(.obsolete)
                        return
                    }
                    try await statuses.updateReadStatus(for: book, rawStatus: rawStatus)
                }
                result = .success(.delivered)
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }
}

@MainActor
@Observable
final class PendingBookEditQueue {
    static var shared: PendingBookEditQueue { ProfileSession.owner.bookEdits }

    let store: PendingBookEditStore
    private(set) var sending: Set<UUID> = []

    @ObservationIgnored var onAcknowledged: (@MainActor (PendingBookEdit) -> Void)?

    @ObservationIgnored private let transport: any PendingBookEditTransporting
    @ObservationIgnored private let connection: @MainActor (UUID) -> ServerConnection?
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private var flushRequested = false
    @ObservationIgnored private var reconnectRequested = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var wasOnline = true
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    init(
        store: PendingBookEditStore,
        transport: any PendingBookEditTransporting,
        connection: @escaping @MainActor (UUID) -> ServerConnection?,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.transport = transport
        self.connection = connection
        self.isEnabled = isEnabled
        self.now = now
    }

    func key(for book: Book, kind: PendingBookEditKind) -> PendingBookEditKey? {
        guard let connection = connection(book.providerId) else { return nil }
        return PendingBookEditKey(
            connectionId: connection.id,
            accountKey: ServerMirrorFingerprint.accountKey(for: connection),
            bookId: book.id,
            kind: kind
        )
    }

    func pendingEdit(for book: Book, kind: PendingBookEditKind) -> PendingBookEdit? {
        guard !store.isEmpty, let key = key(for: book, kind: kind) else { return nil }
        return store.entry(for: key)
    }

    func pendingRating(for book: Book) -> Int? {
        guard case .rating(let rating) = pendingEdit(for: book, kind: .rating)?.value else { return nil }
        return rating
    }

    func status(for book: Book, kind: PendingBookEditKind) -> PendingBookEditStatus? {
        guard let edit = pendingEdit(for: book, kind: kind) else { return nil }
        if sending.contains(edit.revision) { return .sending }
        guard let failure = edit.lastFailure else { return .waiting }
        switch failure.category {
        case .transient: return .retrying(message: failure.message)
        case .authentication: return .needsSignIn
        case .rejected: return .rejected(message: failure.message)
        }
    }

    /// Persists the edit before any network work. Returns nil when the book has no connection to deliver it to.
    @discardableResult
    func submit(_ value: PendingBookEdit.Value, for book: Book) -> PendingBookEdit? {
        guard let key = key(for: book, kind: value.kind) else { return nil }
        return store.enqueue(value, key: key, at: now())
    }

    func retry(_ book: Book, kind: PendingBookEditKind) async {
        guard let edit = pendingEdit(for: book, kind: kind), store.retryNow(edit) else { return }
        await flush()
    }

    @discardableResult
    func discard(_ book: Book, kind: PendingBookEditKind) -> Bool {
        guard let edit = pendingEdit(for: book, kind: kind) else { return false }
        return store.discard(edit)
    }

    func start() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.pathChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.enve.pending-book-edits.network"))
        pathMonitor = monitor
    }

    func retire() async {
        pathMonitor?.cancel()
        pathMonitor = nil
        reconnectTask?.cancel()
        await reconnectTask?.value
        reconnectTask = nil
    }

    private func pathChanged(online: Bool) {
        defer { wasOnline = online }
        guard online, !wasOnline, pathMonitor != nil, !store.isEmpty else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { await self.flush(afterReconnect: true) }
    }

    func flush(afterReconnect: Bool = false) async {
        reconnectRequested = reconnectRequested || afterReconnect
        guard !isFlushing else {
            flushRequested = true
            return
        }
        isFlushing = true
        defer { isFlushing = false }

        var attempted = Set<UUID>()
        repeat {
            flushRequested = false
            if reconnectRequested {
                reconnectRequested = false
                store.resumeTransientRetries()
            }
            resumeReverifiedConnections()
            let ready = store.entriesReady(at: now()).filter { !attempted.contains($0.revision) }
            for edit in ready {
                guard !Task.isCancelled, isEnabled() else { return }
                attempted.insert(edit.revision)
                await deliver(edit)
            }
        } while flushRequested
            || store.entriesReady(at: now()).contains(where: { !attempted.contains($0.revision) })
    }

    /// A sign-in failure parks the edit; it resumes once the connection has been verified again.
    private func resumeReverifiedConnections() {
        for edit in store.suspendedEntries(.authentication) {
            guard let failure = edit.lastFailure,
                let verified = connection(edit.key.connectionId)?.lastVerified,
                verified.timeIntervalSince1970 > failure.occurredAt
            else { continue }
            store.retryNow(edit)
        }
    }

    private func deliver(_ edit: PendingBookEdit) async {
        guard store.isCurrent(edit) else { return }
        guard let connection = connection(edit.key.connectionId) else {
            store.discard(edit)
            return
        }
        // Another account is signed in on this connection; the edit waits for its own account.
        guard ServerMirrorFingerprint.accountKey(for: connection) == edit.key.accountKey else { return }

        sending.insert(edit.revision)
        defer { sending.remove(edit.revision) }
        do {
            switch try await transport.send(edit, isCurrent: { [weak self] in
                guard let self, self.isEnabled(), self.store.isCurrent(edit),
                    let active = self.connection(edit.key.connectionId)
                else { return false }
                return ServerMirrorFingerprint.accountKey(for: active) == edit.key.accountKey
            }) {
            case .delivered:
                if store.acknowledge(edit) { onAcknowledged?(edit) }
            case .unavailable:
                break
            case .obsolete:
                store.discard(edit)
            }
        } catch {
            record(error, for: edit)
        }
    }

    private func record(_ error: any Error, for edit: PendingBookEdit) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        let status = Self.httpStatus(from: error)
        if case .unauthorized = error as? ProviderError {
            store.suspend(edit, failure: failure(.authentication, "The server needs you to sign in again."))
            return
        }
        switch status {
        case 401:
            store.suspend(edit, failure: failure(.authentication, "The server needs you to sign in again."))
        case 403:
            store.suspend(edit, failure: failure(.rejected, "The server refused this change. Your account may not be allowed to make it."))
        case 400, 404, 410, 422:
            store.suspend(edit, failure: failure(.rejected, "The server rejected this change."))
        default:
            store.markRetry(edit, failure: failure(.transient, Self.transientMessage(for: error, status: status)), at: now())
        }
        AppLogger.sync.error(
            "[PendingBookEdit] Delivery failed kind=\(edit.key.kind.rawValue) status=\(status ?? 0) bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: edit.key.uniqueId))"
        )
    }

    private func failure(_ category: PendingBookEditFailure.Category, _ message: String) -> PendingBookEditFailure {
        PendingBookEditFailure(category: category, message: message, occurredAt: now().timeIntervalSince1970)
    }

    private static func transientMessage(for error: any Error, status: Int?) -> String {
        if let status { return "The server returned an error (HTTP \(status))." }
        guard let urlError = error as? URLError else { return "The change couldn't be sent." }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return "This device is offline."
        case .timedOut:
            return "The server took too long to respond."
        default:
            return "The server couldn't be reached."
        }
    }

    private static func httpStatus(from error: any Error) -> Int? {
        guard case .serverError(let message) = error as? ProviderError,
            let range = message.range(of: "HTTP", options: .caseInsensitive)
        else { return nil }
        return message[range.upperBound...]
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .first { (100...599).contains($0) }
    }
}
