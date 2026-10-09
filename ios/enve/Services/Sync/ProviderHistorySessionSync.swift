import Foundation
import Logging

enum HistorySessionUploadError: Error {
    case noMatchingFile
}

@MainActor
final class ProviderHistorySessionSync {
    static var shared: ProviderHistorySessionSync { ProfileSession.owner.historySync }

    private static let storageKey = "enve.providerHistorySessions.uploaded.v1"
    private static let maximumReceiptCount = 5_000
    private var uploadedReceipts: Set<String>
    private let providerResolver: any LibraryProviderResolving
    private let defaults: UserDefaults
    private let bookQuerying: any BookQuerying
    private let historyStore: HistorySessionStore
    private let serverSyncEnabled: @MainActor () -> Bool
    private let historyUploadAllowed: @MainActor (HistorySession) -> Bool
    private let crossProviderSync: CrossProviderHistorySessionSync

    init(
        defaults: UserDefaults,
        bookQuerying: any BookQuerying,
        providerResolver: any LibraryProviderResolving,
        historyStore: HistorySessionStore,
        crossProviderSync: CrossProviderHistorySessionSync,
        serverSyncEnabled: @escaping @MainActor () -> Bool = { true },
        historyUploadAllowed: @escaping @MainActor (HistorySession) -> Bool = { _ in true }
    ) {
        self.serverSyncEnabled = serverSyncEnabled
        self.historyUploadAllowed = historyUploadAllowed
        self.defaults = defaults
        self.bookQuerying = bookQuerying
        self.providerResolver = providerResolver
        self.historyStore = historyStore
        self.crossProviderSync = crossProviderSync
        uploadedReceipts = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func submit(_ session: HistorySession) async -> Bool {
        guard serverSyncEnabled(), historyUploadAllowed(session) else { return false }
        guard session.source == .local, session.durationSeconds >= 10 else { return false }
        let books = await bookQuerying.booksByAnyIds([session.bookId])
        guard let book = books[session.bookId] ?? books.values.first(where: { $0.stableId == session.bookId }) else {
            return false
        }
        return await submit(session, for: book)
    }

    func retryPending(providerId: UUID) async -> Int {
        guard serverSyncEnabled() else { return 0 }
        async let listening = historyStore.loadListeningSessions()
        async let reading = historyStore.loadReadingSessions()
        let (listeningSessions, readingSessions) = await (listening, reading)
        let sessions = (listeningSessions + readingSessions)
            .filter { $0.source == .local && $0.durationSeconds >= 10 }
            .sorted { $0.endTime < $1.endTime }
        guard !sessions.isEmpty else { return 0 }

        let ids = Set(sessions.map(\.bookId))
        let books = await bookQuerying.booksByAnyIds(ids)
        var uploaded = 0
        for session in sessions {
            guard let book = books[session.bookId] ?? books.values.first(where: { $0.stableId == session.bookId }),
                book.providerId == providerId
            else {
                continue
            }
            if await submit(session, for: book) {
                uploaded += 1
            }
        }
        return uploaded
    }

    func pullBookOrbitSessions(provider: BookOrbitProvider, books: [Book]) async -> Int {
        guard serverSyncEnabled() else { return 0 }
        var changed = 0
        for book in books {
            guard serverSyncEnabled() else { return changed }
            do {
                let records = try await provider.fetchReadingSessions(for: book)
                guard serverSyncEnabled() else { return changed }
                let sessions = records.map { record in
                    let endProgress = record.endProgress.map { min(max($0 / 100, 0), 1) }
                    let progressDelta = record.progressDelta.map { min(max($0 / 100, -1), 1) }
                    return HistorySession(
                        id: "bookorbit:\(provider.connection.id.uuidString):\(record.id)",
                        bookId: book.stableId,
                        mediaType: book.mediaType == .audiobook ? "audiobook" : "ebook",
                        startTime: record.startedAt,
                        endTime: record.endedAt,
                        durationSeconds: record.durationSeconds,
                        startProgress: endProgress.flatMap { end in progressDelta.map { end - $0 } },
                        endProgress: endProgress,
                        progressDelta: progressDelta,
                        startLocation: nil,
                        endLocation: nil,
                        pagesRead: nil,
                        source: .bookOrbit
                    )
                }
                changed += await historyStore.replaceBookOrbitSessions(
                    sessions,
                    connectionId: provider.connection.id,
                    bookId: book.stableId,
                    mediaType: book.mediaType
                )
            } catch is CancellationError {
                break
            } catch {
                AppLogger.sync.error(
                    "[BookOrbit] Reading-session pull failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
                )
            }
        }
        if changed > 0 {
            NotificationCenter.default.post(name: .readingStatsDidChange, object: nil)
            NotificationCenter.default.post(name: .listeningStatsDidChange, object: nil)
        }
        return changed
    }

    private func submit(_ session: HistorySession, for book: Book) async -> Bool {
        guard serverSyncEnabled(), historyUploadAllowed(session) else { return false }
        guard let provider = providerResolver.provider(for: book) as? any HistorySessionSyncProvider else {
            return await crossProviderSync.submit(session, for: book)
        }
        let receipt = "\(provider.connection.id.uuidString):\(session.id)"
        guard !uploadedReceipts.contains(receipt) else { return false }

        do {
            try await provider.uploadHistorySession(session, for: book)
            uploadedReceipts.insert(receipt)
            persistReceipts()
            return true
        } catch is CancellationError {
            return false
        } catch HistorySessionUploadError.noMatchingFile {
            // The server can never accept this session, so stop retrying it on every sync.
            uploadedReceipts.insert(receipt)
            persistReceipts()
            return false
        } catch {
            AppLogger.sync.error("[HistorySessionSync] \(provider.connection.type.rawValue) session upload failed: \(error.localizedDescription)")
            return false
        }
    }

    private func persistReceipts() {
        if uploadedReceipts.count > Self.maximumReceiptCount {
            uploadedReceipts = Set(uploadedReceipts.sorted().suffix(Self.maximumReceiptCount))
        }
        defaults.set(Array(uploadedReceipts), forKey: Self.storageKey)
    }
}
