import Foundation
import Logging

@MainActor
final class BookloreAudiobookSyncStrategy: ProviderSyncStrategy {
    let id = "booklore-audiobook"
    let displayName = "Grimmory (Audiobook)"

    private let minimumServerSyncInterval: TimeInterval = 60
    private let largeBookloreLibraryThreshold = 20_000
    private var lastSyncTime: Date?
    private let playbackState: any PlaybackStateProvider = ActivePlayback.controller
    private let providerConnections: any ProviderConnectionAccessing
    private let books: any BookQuerying
    private let bookWriter: any BookWriting

    init(
        providerConnections: any ProviderConnectionAccessing,
        books: any BookQuerying,
        bookWriter: any BookWriting
    ) {
        self.providerConnections = providerConnections
        self.books = books
        self.bookWriter = bookWriter
    }

    func sync(force: Bool, launchOptimized: Bool) async -> ProviderSyncResult {
        let now = Date()
        if !force,
            let lastSyncTime,
            now.timeIntervalSince(lastSyncTime) < minimumServerSyncInterval
        {
            AppLogger.sync.info("Skipping Booklore audiobook batch sync; last run was \(Int(now.timeIntervalSince(lastSyncTime)))s ago")
            return .zero
        }
        lastSyncTime = now

        let currentlyPlaying = playbackState.currentBook?.stableId
        var providerBookById: [UUID: [String: Book]] = [:]
        var providerEligibleCount: [UUID: Int] = [:]

        let totalCachedCount = await books.bookCount()
        let skipFullDbScan = totalCachedCount > 5_000
        if !skipFullDbScan {
            let dbBooks = await books.firstBooks(
                source: Book.BookSource.booklore.rawValue,
                mediaType: "audiobook",
                limit: 5000
            )
            for book in dbBooks {
                providerEligibleCount[book.providerId, default: 0] += 1
                var byId = providerBookById[book.providerId, default: [:]]
                byId[book.id] = book
                providerBookById[book.providerId] = byId
            }
        } else {
            AppLogger.sync.info("Skipping full Grimmory audiobook scan (large library, \(totalCachedCount) books) - recent-only sync")
            for conn in providerConnections.connections where conn.type == .booklore && !conn.isArchived {
                providerBookById[conn.id] = [:]
                providerEligibleCount[conn.id] = 0
            }
        }

        for conn in providerConnections.connections where conn.type == .booklore && !conn.isArchived {
            if let provider = providerConnections.provider(for: conn.id) as? BookloreProvider {
                if providerBookById[provider.connection.id] == nil {
                    providerBookById[provider.connection.id] = [:]
                }
            }
        }

        guard !providerBookById.isEmpty else { return .zero }

        var pullCount = 0
        var pushCount = 0
        var didMutateContinueListeningState = false

        for (providerId, idMap) in providerBookById {
            guard let provider = providerConnections.provider(for: providerId) as? BookloreProvider else { continue }
            let totalEligible = providerEligibleCount[providerId] ?? idMap.count

            if launchOptimized && totalEligible > largeBookloreLibraryThreshold {
                AppLogger.sync.debug(
                    "Skipping Booklore audiobook launch sync providerDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: providerId.uuidString)) books=\(totalEligible)"
                )
                continue
            }

            let selectedBooks: [Book]
            if totalEligible <= 500 {

                selectedBooks = idMap.values
                    .sorted { lhs, rhs in
                        if lhs.lastUpdate != rhs.lastUpdate {
                            return lhs.lastUpdate > rhs.lastUpdate
                        }
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    }
            } else {
                let recentFetchLimit = (launchOptimized && totalEligible > 5_000) ? 12 : 40
                let recentBooks: [GrimmoryRecentBook]
                do {
                    recentBooks = try await provider.fetchRecentBooks(limit: recentFetchLimit)
                } catch {
                    AppLogger.sync.error(
                        "Failed to fetch Booklore recent audiobooks for provider \(providerId): \(error.localizedDescription)"
                    )
                    continue
                }

                let audioLimit = (launchOptimized && totalEligible > largeBookloreLibraryThreshold) ? 6 : 20
                var selected: [Book] = []
                var seenStableIds = Set<String>()
                for recent in recentBooks.prefix(audioLimit * 2) {
                    let bookIdStr = String(recent.bookId)

                    let companionId = BookloreProvider.companionAudiobookIDPrefix + bookIdStr
                    if let localBook = idMap[bookIdStr] ?? idMap[companionId] {
                        if seenStableIds.insert(localBook.stableId).inserted {
                            selected.append(localBook)
                        }
                    } else {

                        var dbBook = await books.book(uniqueId: "\(providerId)_\(bookIdStr)")
                        if dbBook == nil {
                            dbBook = await books.book(uniqueId: "\(providerId)_\(companionId)")
                        }
                        if let dbBook, dbBook.source == .booklore, dbBook.mediaType == .audiobook {
                            if seenStableIds.insert(dbBook.stableId).inserted {
                                selected.append(dbBook)
                            }
                        }
                    }
                    if selected.count >= audioLimit {
                        break
                    }
                }
                selectedBooks = selected
            }

            for book in selectedBooks {
                let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)
                if Task.isCancelled {
                    AppLogger.sync.debug("Booklore audiobook sync cancelled bookDiagnosticID=\(diagnosticID)")
                    return ProviderSyncResult(pulled: pullCount, pushed: pushCount)
                }
                guard book.stableId != currentlyPlaying else { continue }

                do {
                    let local = BookProgressStore.shared.loadProgress(for: book)
                    let localTime = local?.progress ?? book.currentTime
                    let localDate = local.flatMap { Date(timeIntervalSince1970: $0.lastUpdated) } ?? book.lastUpdate

                    guard let serverResult = try await provider.fetchAudiobookProgressState(for: book) else {
                        guard localTime > 1 else { continue }
                        try await provider.updatePlaybackProgress(
                            book: book,
                            sessionId: nil,
                            currentTime: localTime,
                            isFinished: (book.duration ?? 0) > 0 && localTime >= (book.duration ?? 0),
                            timeListened: 0
                        )
                        AppLogger.sync.debug(
                            "Pushed Booklore audiobook to empty server bookDiagnosticID=\(diagnosticID) position=\(Int(localTime))s"
                        )
                        pushCount += 1
                        continue
                    }

                    var persistedBook = book

                    if serverResult.readState.isAbandoned {
                        persistedBook.hideFromContinue = true
                        persistedBook.serverReadStatus = "ABANDONED"
                        let mutated = AppState.shared.mutateBook(stableId: book.stableId) {
                            $0.hideFromContinue = true
                            $0.serverReadStatus = "ABANDONED"
                        }
                        if mutated == nil {
                            await bookWriter.upsertBooks([persistedBook])
                        }
                        didMutateContinueListeningState = true
                        BookProgressStore.shared.remove(stableId: book.stableId)
                        AppLogger.sync.debug("Grimmory audiobook marked abandoned bookDiagnosticID=\(diagnosticID)")
                        continue
                    }

                    if serverResult.readState.isFinished || serverResult.readState == .notReading {
                        persistedBook.serverReadStatus = serverResult.readState.persistedStatus
                        persistedBook.isFinished = serverResult.readState.isFinished
                        persistedBook.hideFromContinue = true
                        persistedBook.lastUpdate = serverResult.updatedAt ?? book.lastUpdate
                        if serverResult.positionSeconds > 0 {
                            persistedBook.currentTime = serverResult.positionSeconds
                            BookProgressStore.shared.saveProgress(
                                for: book,
                                progress: serverResult.positionSeconds,
                                duration: book.duration ?? 0
                            )
                        }
                        let mutated = AppState.shared.mutateBook(stableId: book.stableId) {
                            $0.serverReadStatus = persistedBook.serverReadStatus
                            $0.isFinished = persistedBook.isFinished
                            $0.hideFromContinue = true
                            $0.lastUpdate = persistedBook.lastUpdate
                            if serverResult.positionSeconds > 0 { $0.currentTime = serverResult.positionSeconds }
                        }
                        if mutated == nil {
                            await bookWriter.upsertBooks([persistedBook])
                        }
                        didMutateContinueListeningState = true
                        pullCount += 1
                        continue
                    }

                    persistedBook.hideFromContinue = false
                    persistedBook.serverReadStatus = serverResult.readState.persistedStatus ?? "READING"

                    let serverTime = serverResult.positionSeconds
                    let serverDate = serverResult.updatedAt ?? .distantPast
                    let duration = book.duration ?? 0

                    let direction = resolveProgressConflictWithBackwardCheck(
                        localPosition: localTime,
                        localDate: localDate,
                        serverPosition: serverTime,
                        serverDate: serverDate
                    )

                    switch direction {
                    case .pull:
                        BookProgressStore.shared.saveProgress(for: book, progress: serverTime, duration: duration)
                        if let stamp = serverResult.updatedAt {
                            BookProgressStore.shared.saveServerStamp(for: book, stamp)
                        }
                        persistedBook.currentTime = serverTime
                        persistedBook.lastUpdate = serverDate
                        if duration > 0 {
                            persistedBook.isFinished = serverResult.percentage >= 0.99
                        }
                        let isPercentFinished = serverResult.percentage >= 0.99
                        let mutated = AppState.shared.mutateBook(stableId: book.stableId) {
                            $0.hideFromContinue = false
                            $0.serverReadStatus = serverResult.readState.persistedStatus ?? "READING"
                            $0.currentTime = serverTime
                            $0.lastUpdate = serverDate
                            if duration > 0 { $0.isFinished = isPercentFinished }
                        }
                        if mutated == nil {
                            await bookWriter.upsertBooks([persistedBook])
                        }
                        didMutateContinueListeningState = true
                        AppLogger.sync.debug(
                            "Pulled Booklore audiobook progress bookDiagnosticID=\(diagnosticID) position=\(Int(serverTime))s"
                        )
                        pullCount += 1
                    case .push:
                        let mutated = AppState.shared.mutateBook(stableId: book.stableId) {
                            $0.hideFromContinue = false
                            $0.serverReadStatus = serverResult.readState.persistedStatus ?? "READING"
                        }
                        if mutated == nil {
                            await bookWriter.upsertBooks([persistedBook])
                        }
                        didMutateContinueListeningState = true
                        try await provider.updatePlaybackProgress(
                            book: book,
                            sessionId: nil,
                            currentTime: localTime,
                            isFinished: duration > 0 && localTime >= duration,
                            timeListened: 0
                        )
                        AppLogger.sync.debug(
                            "Pushed Booklore audiobook progress bookDiagnosticID=\(diagnosticID) position=\(Int(localTime))s"
                        )
                        pushCount += 1
                    case .conflict, .none:
                        let mutated = AppState.shared.mutateBook(stableId: book.stableId) {
                            $0.hideFromContinue = false
                            $0.serverReadStatus = serverResult.readState.persistedStatus ?? "READING"
                        }
                        if mutated == nil {
                            await bookWriter.upsertBooks([persistedBook])
                        }
                        didMutateContinueListeningState = true
                        if direction == .conflict {
                            AppLogger.sync.info(
                                "Booklore audiobook backward conflict bookDiagnosticID=\(diagnosticID) local=\(Int(localTime))s server=\(Int(serverTime))s"
                            )
                        }
                    }
                } catch {
                    AppLogger.sync.error(
                        "Failed to sync Booklore audiobook bookDiagnosticID=\(diagnosticID): \(error.localizedDescription)"
                    )
                }
            }
        }

        if didMutateContinueListeningState {

            await MainActor.run {
                NotificationCenter.default.post(name: .continueListeningNeedsRefresh, object: nil)
            }
        }
        return ProviderSyncResult(pulled: pullCount, pushed: pushCount)
    }
}
