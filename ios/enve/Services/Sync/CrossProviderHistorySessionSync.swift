import Foundation

@MainActor
final class CrossProviderHistorySessionSync {
    static let shared = CrossProviderHistorySessionSync(
        defaults: .standard,
        bookQuerying: AppState.shared.bookStore,
        providerResolver: AppState.shared.providerConnections,
        historyStore: .shared,
        listeningStore: .shared
    )

    struct Mapping: Codable, Equatable {
        let sourceBookId: String
        let sourceAccountId: String
        let includeEarlierHistory: Bool
        let targetConnectionId: UUID
        let targetItemId: String
        let targetAccountId: String
        let confirmedAt: Date
    }

    static func canUpload(
        sessionStart: Date, sessionEnd: Date, confirmedAt: Date,
        includeEarlierHistory: Bool, progressUpdatedAt: Date?
    ) -> Bool {
        if sessionStart >= confirmedAt { return true }
        return includeEarlierHistory && progressUpdatedAt.map { $0 > sessionEnd } == true
    }

    private let storageKey = "enve.crossProviderHistoryMappings.v1"
    private let receiptsKey = "enve.crossProviderHistoryReceipts.v1"
    private let defaults: UserDefaults
    private let bookQuerying: any BookQuerying
    private let providerResolver: any LibraryProviderResolving
    private let historyStore: HistorySessionStore
    private let serverSyncEnabled: @MainActor () -> Bool
    private let historyUploadAllowed: @MainActor (HistorySession) -> Bool
    private let listeningStore: ABSLocalListeningStore
    private var mappings: [String: Mapping]
    private var receipts: Set<String>
    private var inFlight: Set<String> = []

    init(
        defaults: UserDefaults,
        bookQuerying: any BookQuerying,
        providerResolver: any LibraryProviderResolving,
        historyStore: HistorySessionStore,
        listeningStore: ABSLocalListeningStore,
        serverSyncEnabled: @escaping @MainActor () -> Bool = { true },
        historyUploadAllowed: @escaping @MainActor (HistorySession) -> Bool = { _ in true }
    ) {
        self.serverSyncEnabled = serverSyncEnabled
        self.historyUploadAllowed = historyUploadAllowed
        self.defaults = defaults
        self.bookQuerying = bookQuerying
        self.providerResolver = providerResolver
        self.historyStore = historyStore
        self.listeningStore = listeningStore
        mappings = (defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: Mapping].self, from: $0) }) ?? [:]
        receipts = Set(defaults.stringArray(forKey: receiptsKey) ?? [])
    }

    func mapping(for book: Book) -> Mapping? { mappings[book.stableId] }

    func confirm(source: Book, target: Book, includeEarlierHistory: Bool) async throws {
        guard source.mediaType == .audiobook, source.source == .booklore,
            target.mediaType == .audiobook, target.source == .audiobookshelf,
            let sourceProvider = providerResolver.provider(for: source.providerId) as? BookloreProvider,
            let provider = providerResolver.provider(for: target.providerId) as? AudiobookshelfProvider
        else { throw ProviderError.invalidResponse }
        let verified = try await provider.fetchFullBookDetails(bookId: target.id, libraryId: target.libraryId)
        guard verified.providerId == target.providerId,
            AudiobookshelfProvider.libraryItemId(for: verified) == AudiobookshelfProvider.libraryItemId(for: target)
        else { throw ProviderError.invalidResponse }
        let sourceAccountId = String(try await sourceProvider.fetchCurrentUser().id)
        let accountId = try await provider.currentAccountId()
        mappings[source.stableId] = Mapping(
            sourceBookId: source.stableId,
            sourceAccountId: sourceAccountId,
            includeEarlierHistory: includeEarlierHistory,
            targetConnectionId: target.providerId,
            targetItemId: AudiobookshelfProvider.libraryItemId(for: target),
            targetAccountId: accountId,
            confirmedAt: .now
        )
        persist()
    }

    func remove(source: Book) {
        mappings.removeValue(forKey: source.stableId)
        persist()
    }

    func submit(_ session: HistorySession, for source: Book) async -> Bool {
        guard serverSyncEnabled(), historyUploadAllowed(session) else { return false }
        guard session.source == .local, session.mediaType == "audiobook", session.durationSeconds >= 10,
            source.stableId == session.bookId, source.source == .booklore,
            let mapping = mappings[source.stableId]
        else { return false }
        guard let sourceProvider = providerResolver.provider(for: source.providerId) as? BookloreProvider,
            let provider = providerResolver.provider(for: mapping.targetConnectionId) as? AudiobookshelfProvider else {
            return false
        }
        do {
            guard String(try await sourceProvider.fetchCurrentUser().id) == mapping.sourceAccountId,
                try await provider.currentAccountId() == mapping.targetAccountId else { return false }
            let books = await bookQuerying.books(
                source: Book.BookSource.audiobookshelf.rawValue, providerId: mapping.targetConnectionId,
                mediaType: AppMediaType.audiobook.rawValue
            )
            guard let target = books.first(where: { AudiobookshelfProvider.libraryItemId(for: $0) == mapping.targetItemId })
            else { return false }
            let receipt = "\(mapping.targetConnectionId.uuidString):\(mapping.targetAccountId):\(mapping.targetItemId):\(session.id)"
            guard !receipts.contains(receipt), inFlight.insert(receipt).inserted else { return false }
            defer { inFlight.remove(receipt) }
            let progress = try await provider.fetchAudiobookProgress(for: target)
            guard Self.canUpload(
                sessionStart: session.startTime, sessionEnd: session.endTime,
                confirmedAt: mapping.confirmedAt, includeEarlierHistory: mapping.includeEarlierHistory,
                progressUpdatedAt: progress?.updatedAt
            ) else { return false }
            guard let queued = ABSCrossProviderHistory.session(
                from: session, targetConnectionId: mapping.targetConnectionId,
                targetAccountId: mapping.targetAccountId, targetBook: target,
                currentProgress: progress?.positionSeconds ?? 0
            ) else { return false }
            guard serverSyncEnabled(), historyUploadAllowed(session) else { return false }
            listeningStore.enqueueHistory(queued)
            let uploaded = await provider.flushHistorySessions(listeningStore: listeningStore)
            guard uploaded.contains(queued.id) else { return false }
            receipts.insert(receipt)
            if receipts.count > 5_000 { receipts = Set(receipts.sorted().suffix(5_000)) }
            defaults.set(Array(receipts), forKey: receiptsKey)
            return true
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    func retryPending(targetConnectionId: UUID) async -> Int {
        guard serverSyncEnabled() else { return 0 }
        let relevant = mappings.filter { $0.value.targetConnectionId == targetConnectionId }
        guard !relevant.isEmpty else { return 0 }
        let sessions = await historyStore.loadListeningSessions()
            .filter { $0.source == .local && $0.durationSeconds >= 10 }
            .sorted { $0.endTime < $1.endTime }
        let books = await bookQuerying.booksByAnyIds(Set(sessions.map(\.bookId)))
        var uploaded = 0
        for session in sessions {
            guard let source = books[session.bookId] ?? books.values.first(where: { $0.stableId == session.bookId }),
                relevant[source.stableId] != nil else { continue }
            if await submit(session, for: source) { uploaded += 1 }
        }
        return uploaded
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(mappings), forKey: storageKey)
    }
}
