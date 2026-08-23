import Foundation
import Logging

@MainActor
final class ProviderHistorySessionSync {
    static let shared = ProviderHistorySessionSync(providerResolver: AppState.shared.providerConnections)

    private static let storageKey = "enve.providerHistorySessions.uploaded.v1"
    private static let maximumReceiptCount = 5_000
    private var uploadedReceipts: Set<String>
    private let providerResolver: any LibraryProviderResolving

    private init(providerResolver: any LibraryProviderResolving) {
        self.providerResolver = providerResolver
        uploadedReceipts = Set(UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? [])
    }

    func submit(_ session: HistorySession) async -> Bool {
        guard session.source == .local, session.durationSeconds >= 10 else { return false }
        let books = await AppState.shared.bookStore.booksByAnyIds([session.bookId])
        guard let book = books[session.bookId] ?? books.values.first(where: { $0.stableId == session.bookId }) else {
            return false
        }
        return await submit(session, for: book)
    }

    func retryPending(providerId: UUID) async -> Int {
        async let listening = HistorySessionStore.shared.loadListeningSessions()
        async let reading = HistorySessionStore.shared.loadReadingSessions()
        let (listeningSessions, readingSessions) = await (listening, reading)
        let sessions = (listeningSessions + readingSessions)
            .filter { $0.source == .local && $0.durationSeconds >= 10 }
            .sorted { $0.endTime < $1.endTime }
        guard !sessions.isEmpty else { return 0 }

        let ids = Set(sessions.map(\.bookId))
        let books = await AppState.shared.bookStore.booksByAnyIds(ids)
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
        var changed = 0
        for book in books {
            do {
                let records = try await provider.fetchReadingSessions(for: book)
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
                changed += await HistorySessionStore.shared.replaceBookOrbitSessions(
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
        guard let provider = providerResolver.provider(for: book) as? any HistorySessionSyncProvider else {
            return false
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
        } catch {
            AppLogger.sync.error("[HistorySessionSync] \(provider.connection.type.rawValue) session upload failed: \(error.localizedDescription)")
            return false
        }
    }

    private func persistReceipts() {
        if uploadedReceipts.count > Self.maximumReceiptCount {
            uploadedReceipts = Set(uploadedReceipts.sorted().suffix(Self.maximumReceiptCount))
        }
        UserDefaults.standard.set(Array(uploadedReceipts), forKey: Self.storageKey)
    }
}
