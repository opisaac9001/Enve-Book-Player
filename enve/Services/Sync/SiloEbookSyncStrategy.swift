import Foundation
import Logging

@MainActor
final class SiloEbookSyncStrategy: ProviderSyncStrategy {
    let id = "silo-ebook"
    let displayName = "Silo (Ebook)"

    private let minimumServerSyncInterval: TimeInterval = 60
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
            return .zero
        }
        lastSyncTime = now

        let activeBookId = playbackState.currentBook?.stableId
        let connections = providerConnections.activeConnections(of: .silo)
        guard !connections.isEmpty else { return .zero }

        var pulled = 0
        var pushed = 0
        var updatedBooks: [Book] = []

        for connection in connections {
            guard let provider = providerConnections.provider(for: connection.id) as? SiloProvider else { continue }
            do {
                _ = try await provider.fetchLibraries()
            } catch {
                AppLogger.sync.debug(
                    "Skipping Silo ebook sync providerDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: connection.id.uuidString)): \(error.localizedDescription)"
                )
                continue
            }

            let candidateBooks = await books.firstBooks(
                source: Book.BookSource.silo.rawValue,
                mediaType: "ebook",
                limit: launchOptimized ? 100 : 1000
            ).filter { $0.providerId == connection.id }

            for book in candidateBooks where book.stableId != activeBookId {
                do {
                    let localProgress = book.ebookProgress ?? book.canonicalEbookProgress
                    let localDate = book.lastUpdate

                    guard let serverResult = try await provider.fetchEbookProgress(for: book) else {
                        guard localProgress > 0.001 else { continue }
                        try await provider.updateEbookProgress(
                            for: book,
                            progress: localProgress,
                            epubLocator: book.epubLocator
                        )
                        pushed += 1
                        continue
                    }

                    let serverProgress = serverResult.progress
                    let serverDate = serverResult.updatedAt ?? .distantPast
                    let resolvedDirection = resolveProgressConflictWithBackwardCheck(
                        localPosition: localProgress,
                        localDate: localDate,
                        serverPosition: serverProgress,
                        serverDate: serverDate
                    )
                    let direction: SyncDirection
                    if serverDate > localDate,
                        let serverLocator = serverResult.locator,
                        !serverLocator.isEmpty,
                        serverLocator != book.epubLocator
                    {
                        direction = .pull
                    } else {
                        direction = resolvedDirection
                    }

                    switch direction {
                    case .pull:
                        let isFinished = serverResult.isAbandoned || serverProgress >= 0.99
                        let mutated = AppState.shared.mutateBook(stableId: book.stableId) {
                            $0.hideFromContinue = false
                            $0.ebookProgress = serverProgress
                            if let locator = serverResult.locator, !locator.isEmpty {
                                $0.epubLocator = locator
                            }
                            $0.isFinished = isFinished
                            $0.serverReadStatus = isFinished ? "READ" : "READING"
                            $0.lastUpdate = serverDate
                        }
                        if let mutated {
                            updatedBooks.append(mutated)
                        } else {
                            await progressRepository.updateEbookProgress(
                                uniqueId: book.uniqueId,
                                ebookProgress: serverProgress,
                                epubLocator: serverResult.locator,
                                isFinished: isFinished,
                                lastUpdate: serverDate
                            )
                        }
                        EbookLinkStore.shared.saveLinks()
                        AppLogger.sync.debug(
                            "Pulled Silo ebook progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) progress=\(Int(serverProgress * 100))%"
                        )
                        pulled += 1

                    case .push:
                        try await provider.updateEbookProgress(
                            for: book,
                            progress: localProgress,
                            epubLocator: book.epubLocator
                        )
                        pushed += 1

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
                            "Silo ebook backward conflict bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) local=\(Int(localProgress * 100))% server=\(Int(serverProgress * 100))%"
                        )

                    case .none:
                        break
                    }
                } catch {
                    AppLogger.sync.error(
                        "Failed to sync Silo ebook bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
                    )
                }
            }
        }

        if !updatedBooks.isEmpty {
            await bookWriter.upsertBooks(updatedBooks)
        }

        return ProviderSyncResult(pulled: pulled, pushed: pushed)
    }
}
