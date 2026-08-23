import Foundation
import Logging

@MainActor
final class BookloreEbookSyncStrategy: ProviderSyncStrategy {
    let id = "booklore-ebook"
    let displayName = "Grimmory (Ebook)"

    private let minimumServerSyncInterval: TimeInterval = 60
    private let largeBookloreLibraryThreshold = 20_000
    private var lastSyncTime: Date?
    private let playbackState: any PlaybackStateProvider = ActivePlayback.controller
    private let providerConnections: any ProviderConnectionAccessing
    private let books: any BookQuerying
    private let bookWriter: any BookWriting
    private let progressRepository: any ProgressRepository

    init(
        providerConnections: any ProviderConnectionAccessing,
        books: any BookQuerying,
        bookWriter: any BookWriting,
        progressRepository: any ProgressRepository
    ) {
        self.providerConnections = providerConnections
        self.books = books
        self.bookWriter = bookWriter
        self.progressRepository = progressRepository
    }

    func sync(force: Bool, launchOptimized: Bool) async -> ProviderSyncResult {
        let now = Date()
        if !force,
            let lastSyncTime,
            now.timeIntervalSince(lastSyncTime) < minimumServerSyncInterval
        {
            AppLogger.sync.info("Skipping Booklore ebook batch sync; last run was \(Int(now.timeIntervalSince(lastSyncTime)))s ago")
            return .zero
        }
        lastSyncTime = now

        var absorbedIds = Set<String>()
        var providerBookById: [UUID: [String: Book]] = [:]
        var providerBookByStableId: [UUID: [String: Book]] = [:]
        var providerEligibleCount: [UUID: Int] = [:]
        var conflictBookIdsByProvider: [UUID: [String]] = [:]

        let playingBookId = playbackState.currentBook?.stableId

        let totalCachedCount = await books.bookCount()
        let skipFullDbScan = totalCachedCount > 5_000
        if !skipFullDbScan {
            for book in await books.firstBooksWithReadAloudSource(limit: 5000) {
                if let s = book.readAloudSourceStableId { absorbedIds.insert(s) }
                if let a = book.linkedAudiobookStableId { absorbedIds.insert(a) }
            }
        } else {
            AppLogger.sync.info("Skipping full Grimmory ebook scan (large library, \(totalCachedCount) books) - recent-only sync")
            for conn in providerConnections.connections where conn.type == .booklore && !conn.isArchived {
                providerBookById[conn.id] = [:]
                providerBookByStableId[conn.id] = [:]
                providerEligibleCount[conn.id] = 0
            }
        }

        if !skipFullDbScan {
            let dbBooks = await books.firstBooks(
                source: Book.BookSource.booklore.rawValue,
                mediaType: "ebook",
                limit: 5000
            )
            for book in dbBooks {
                guard !absorbedIds.contains(book.stableId) else { continue }
                providerEligibleCount[book.providerId, default: 0] += 1
                var byId = providerBookById[book.providerId, default: [:]]
                byId[book.id] = book
                providerBookById[book.providerId] = byId

                var byStable = providerBookByStableId[book.providerId, default: [:]]
                byStable[book.stableId] = book
                providerBookByStableId[book.providerId] = byStable
            }
        } else {
            AppLogger.sync.info("Skipping full Grimmory ebook DB scan at launch (large library) - recent-only sync via fetchRecentBooks")
        }

        for conn in providerConnections.connections where conn.type == .booklore && !conn.isArchived {
            if let provider = providerConnections.provider(for: conn.id) as? BookloreProvider {
                if providerBookById[provider.connection.id] == nil {
                    providerBookById[provider.connection.id] = [:]
                }
            }
        }

        guard !providerBookById.isEmpty else { return .zero }

        for conflict in EbookConflictStore.shared.pending {
            for (providerId, stableMap) in providerBookByStableId where stableMap[conflict.bookStableId] != nil {
                conflictBookIdsByProvider[providerId, default: []].append(conflict.bookStableId)
                break
            }
        }

        var pullCount = 0
        var pushCount = 0
        var updatedInMemoryBooks: [Book] = []

        for (providerId, idMap) in providerBookById {
            guard let provider = providerConnections.provider(for: providerId) as? BookloreProvider else { continue }
            let totalEligible = providerEligibleCount[providerId] ?? idMap.count

            if launchOptimized && totalEligible > largeBookloreLibraryThreshold {
                AppLogger.sync.debug(
                    "Skipping Booklore ebook launch sync providerDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: providerId.uuidString)) books=\(totalEligible)"
                )
                continue
            }

            var prioritizedBooks: [Book] = []
            var seenStableIds = Set<String>()
            let recentFetchLimit = (launchOptimized && totalEligible > 5_000) ? 12 : 40

            do {
                let recentBooks = try await provider.fetchRecentBooks(limit: recentFetchLimit)
                for recent in recentBooks {
                    let bookIdStr = String(recent.bookId)
                    if let localBook = idMap[bookIdStr] {
                        if seenStableIds.insert(localBook.stableId).inserted {
                            prioritizedBooks.append(localBook)
                        }
                    } else {

                        let uid = "\(providerId)_\(bookIdStr)"
                        if let dbBook = await books.book(uniqueId: uid),
                            dbBook.source == .booklore, dbBook.mediaType == .ebook
                        {
                            if seenStableIds.insert(dbBook.stableId).inserted {
                                prioritizedBooks.append(dbBook)
                            }
                        }
                    }
                }
            } catch {
                AppLogger.sync.error(
                    "Failed to fetch Booklore recent books providerDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: providerId.uuidString)): \(error.localizedDescription)"
                )
            }

            let extraConflictLimit = (launchOptimized && totalEligible > 5_000) ? 4 : 12
            if let conflictIds = conflictBookIdsByProvider[providerId],
                let stableMap = providerBookByStableId[providerId]
            {
                for stableId in conflictIds.prefix(extraConflictLimit) {
                    guard let conflictBook = stableMap[stableId] else { continue }
                    if seenStableIds.insert(conflictBook.stableId).inserted {
                        prioritizedBooks.append(conflictBook)
                    }
                }
            }

            AppLogger.sync.info(
                "Booklore ebook batch sync providerDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: providerId.uuidString)) candidates=\(prioritizedBooks.count) indexedProviderBooks=\(totalEligible)"
            )

            for book in prioritizedBooks {
                let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)
                if Task.isCancelled {
                    AppLogger.sync.debug("Booklore ebook sync cancelled bookDiagnosticID=\(diagnosticID)")
                    return ProviderSyncResult(pulled: pullCount, pushed: pushCount)
                }
                guard book.stableId != playingBookId else { continue }

                do {
                    let localProgress = book.ebookProgress ?? 0
                    let localDate = book.lastUpdate

                    guard let serverResult = try await provider.fetchEbookProgressState(for: book) else {
                        guard localProgress > 0.001 else { continue }
                        try? await provider.updateEbookProgress(for: book, progress: localProgress, epubLocator: book.epubLocator)
                        AppLogger.sync.info(
                            "Pushed Booklore ebook progress to empty server state bookDiagnosticID=\(diagnosticID) progress=\(Int(localProgress * 100))%"
                        )
                        pushCount += 1
                        continue
                    }

                    if serverResult.readState.isAbandoned {
                        var hiddenBook = book
                        hiddenBook.hideFromContinue = true
                        hiddenBook.serverReadStatus = "ABANDONED"
                        let mutated = AppState.shared.mutateBook(stableId: book.stableId) {
                            $0.hideFromContinue = true
                            $0.serverReadStatus = "ABANDONED"
                        }
                        if mutated == nil {
                            await bookWriter.upsertBooks([hiddenBook])
                        }
                        BookProgressStore.shared.remove(stableId: book.stableId)
                        EbookConflictStore.shared.remove(stableId: book.stableId)
                        AppLogger.sync.debug("Grimmory ebook marked abandoned bookDiagnosticID=\(diagnosticID)")
                        continue
                    }

                    if serverResult.readState.isFinished || serverResult.readState == .notReading {
                        var statusBook = book
                        statusBook.serverReadStatus = serverResult.readState.persistedStatus
                        statusBook.isFinished = serverResult.readState.isFinished
                        statusBook.hideFromContinue = true
                        statusBook.lastUpdate = serverResult.updatedAt ?? book.lastUpdate
                        if serverResult.progress > 0 {
                            statusBook.ebookProgress = serverResult.progress
                        }
                        if let locator = serverResult.locator, !locator.isEmpty {
                            statusBook.epubLocator = locator
                        }
                        let mutated = AppState.shared.mutateBook(stableId: book.stableId) {
                            $0.serverReadStatus = statusBook.serverReadStatus
                            $0.isFinished = statusBook.isFinished
                            $0.hideFromContinue = true
                            $0.lastUpdate = statusBook.lastUpdate
                            if serverResult.progress > 0 { $0.ebookProgress = serverResult.progress }
                            if let locator = serverResult.locator, !locator.isEmpty { $0.epubLocator = locator }
                        }
                        updatedInMemoryBooks.append(mutated ?? statusBook)
                        EbookConflictStore.shared.remove(stableId: book.stableId)
                        pullCount += 1
                        continue
                    }

                    let serverProgress = serverResult.progress
                    let serverDate = serverResult.updatedAt ?? .distantPast

                    let direction = resolveProgressConflictWithBackwardCheck(
                        localPosition: localProgress,
                        localDate: localDate,
                        serverPosition: serverProgress,
                        serverDate: serverDate
                    )

                    switch direction {
                    case .pull:
                        let resolvedLocator = serverResult.locator
                        let mutated = AppState.shared.mutateBook(stableId: book.stableId) {
                            $0.hideFromContinue = false
                            $0.ebookProgress = serverProgress
                            $0.isFinished = serverResult.readState.isFinished || serverProgress >= 0.99
                            $0.serverReadStatus =
                                serverResult.readState.persistedStatus
                                ?? (serverProgress >= 0.99 ? "READ" : "READING")
                            if let loc = resolvedLocator, !loc.isEmpty { $0.epubLocator = loc }
                            $0.lastUpdate = serverDate
                        }
                        if let mutated {
                            updatedInMemoryBooks.append(mutated)
                        } else {

                            await progressRepository.updateEbookProgress(
                                uniqueId: book.uniqueId,
                                ebookProgress: serverProgress,
                                epubLocator: serverResult.locator,
                                isFinished: serverResult.readState.isFinished || serverProgress >= 0.99,
                                lastUpdate: serverDate
                            )
                        }
                        EbookLinkStore.shared.saveLinks()
                        AppLogger.sync.debug(
                            "Pulled Booklore ebook progress bookDiagnosticID=\(diagnosticID) progress=\(Int(serverProgress * 100))%"
                        )
                        pullCount += 1
                    case .push:
                        try? await provider.updateEbookProgress(for: book, progress: localProgress, epubLocator: book.epubLocator)
                        AppLogger.sync.debug(
                            "Pushed Booklore ebook progress bookDiagnosticID=\(diagnosticID) progress=\(Int(localProgress * 100))%"
                        )
                        pushCount += 1
                    case .conflict:
                        EbookConflictStore.shared.add(
                            EbookSyncConflict(
                                bookStableId: book.stableId,
                                bookTitle: book.title,
                                localProgress: localProgress,
                                serverProgress: serverProgress,
                                serverLocator: serverResult.locator,
                                serverDate: serverDate
                            )
                        )
                        AppLogger.sync.info(
                            "Booklore ebook backward conflict bookDiagnosticID=\(diagnosticID) local=\(Int(localProgress * 100))% server=\(Int(serverProgress * 100))%"
                        )
                    case .none:
                        break
                    }
                } catch {
                    AppLogger.sync.error(
                        "Failed to sync Booklore ebook bookDiagnosticID=\(diagnosticID): \(String(reflecting: error))"
                    )
                }
            }
        }

        if !updatedInMemoryBooks.isEmpty {
            await bookWriter.upsertBooks(updatedInMemoryBooks)
        }

        return ProviderSyncResult(pulled: pullCount, pushed: pushCount)
    }
}
