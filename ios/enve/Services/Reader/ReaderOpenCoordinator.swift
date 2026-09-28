import Foundation
import Logging

@MainActor
@Observable
final class ReaderOpenCoordinator {
    static let shared = ReaderOpenCoordinator()

    enum Phase: Equatable {
        case downloading
        case preparing
        case failed(String)
    }

    struct Activity: Identifiable, Equatable {
        let id: UUID
        let book: Book
        let locator: String?
        var phase: Phase
        var directProgress: Double?
    }

    private(set) var activity: Activity?

    @ObservationIgnored private let appState: AppState
    @ObservationIgnored private let downloads: UnifiedDownloadService
    @ObservationIgnored private let linkedProgress: LinkedBookProgressCoordinator
    @ObservationIgnored private let present: (Book) -> Void
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var requestedBookID: String?

    init(
        appState: AppState = .shared,
        downloads: UnifiedDownloadService = .shared,
        linkedProgress: LinkedBookProgressCoordinator = .shared,
        present: ((Book) -> Void)? = nil
    ) {
        self.appState = appState
        self.downloads = downloads
        self.linkedProgress = linkedProgress
        self.present =
            present ?? { book in
                LastOpenedBookStore.shared.record(book)
                appState.presentation.selectedEbookForDetail = book
            }
    }

    // Only pass a locator for an explicit jump. A stale book copy could overwrite newer server progress.
    func open(_ book: Book, at locator: String? = nil) {
        let requestedLocator = locator?.isEmpty == false ? locator : nil
        if requestedBookID == book.uniqueId, requestTask != nil {
            return
        }
        if requestedLocator != nil {
            AppLogger.general.info("[ReaderOpen] opening at an explicit locator bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))")
        }

        cancelCurrentRequest(removeActivity: true)

        guard requiresPreparation(book) else {
            requestedBookID = book.uniqueId
            requestTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let resolved = await self.resolveLinkedProgress(
                    for: book,
                    requestedLocator: requestedLocator
                )
                guard !Task.isCancelled, self.requestedBookID == book.uniqueId else { return }
                self.present(resolved)
                self.requestTask = nil
                self.requestedBookID = nil
            }
            return
        }

        let requestID = UUID()
        requestedBookID = book.uniqueId
        activity = Activity(
            id: requestID,
            book: book,
            locator: requestedLocator,
            phase: .downloading,
            directProgress: nil
        )
        requestTask = Task { @MainActor [weak self] in
            await self?.prepareAndOpen(
                book,
                requestID: requestID,
                requestedLocator: requestedLocator
            )
        }
    }

    func cancel() {
        cancelCurrentRequest(removeActivity: true)
    }

    func retry() {
        guard let activity else { return }
        cancelCurrentRequest(removeActivity: true)
        open(activity.book, at: activity.locator)
    }

    func dismissFailure() {
        guard let currentActivity = activity, case .failed = currentActivity.phase else { return }
        activity = nil
    }

    private func prepareAndOpen(
        _ book: Book,
        requestID: UUID,
        requestedLocator: String?
    ) async {
        do {
            let fileURL = try await downloads.prepareReaderAsset(for: book) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard self?.activity?.id == requestID else { return }
                    self?.activity?.directProgress = min(max(progress, 0), 1)
                }
            }
            try Task.checkCancellation()
            guard activity?.id == requestID else { return }

            activity?.phase = .preparing
            var prepared = await appState.bookStore.book(uniqueId: book.uniqueId) ?? book
            prepared.ebookFileURL = fileURL
            if let requestedLocator {
                prepared.epubLocator = requestedLocator
            }
            let resolved = await resolveLinkedProgress(
                for: prepared,
                requestedLocator: requestedLocator
            )
            try Task.checkCancellation()
            guard activity?.id == requestID else { return }
            appState.hotCache.insert(resolved)
            present(resolved)
            activity = nil
            requestTask = nil
            requestedBookID = nil
        } catch is CancellationError {
            guard activity?.id == requestID else { return }
            activity = nil
            requestTask = nil
            requestedBookID = nil
        } catch {
            guard activity?.id == requestID else { return }
            activity?.phase = .failed(error.localizedDescription)
            requestTask = nil
        }
    }

    private func requiresPreparation(_ book: Book) -> Bool {
        if downloads.existingReaderAsset(for: book) != nil {
            return false
        }
        if book.source == .local || book.source == .komga || book.isComic || book.isReadAloudBook {
            return false
        }
        if GrimmoryEpubStreaming.isEligible(book) {

            return false
        }
        return book.mediaType == .ebook
            || book.hasAlternateFormat
            || book.epub3Features?.hasMediaOverlay == true
    }

    private func resolveLinkedProgress(
        for book: Book,
        requestedLocator: String?
    ) async -> Book {
        if let requestedLocator {
            var requested = book
            requested.epubLocator = requestedLocator
            guard book.mediaType == .ebook,
                let progression = Book.progressFromEbookLocator(requestedLocator)
            else {
                return requested
            }

            let observedAt = Date()
            requested.ebookProgress = progression
            requested.isFinished = progression >= Book.finishedProgressThreshold
            requested.serverReadStatus = requested.isFinished ? "READ" : nil
            requested.lastUpdate = observedAt
            if appState.mutateBook(
                uniqueId: requested.uniqueId,
                {
                    $0.epubLocator = requestedLocator
                    $0.ebookProgress = progression
                    $0.isFinished = progression >= Book.finishedProgressThreshold
                    $0.serverReadStatus = progression >= Book.finishedProgressThreshold ? "READ" : nil
                    $0.lastUpdate = observedAt
                }
            ) == nil {
                appState.hotCache.insert(requested)
            }
            EbookLinkStore.shared.saveLinks()
            await appState.bookStore.updateEbookProgress(
                uniqueId: requested.uniqueId,
                ebookProgress: progression,
                epubLocator: requestedLocator,
                isFinished: requested.isFinished,
                lastUpdate: observedAt
            )
            await linkedProgress.recordEbookProgress(
                book: requested,
                progression: progression,
                observedAt: observedAt,
                authoritative: true
            )
            return requested
        }

        await linkedProgress.reconcilePair(for: book)
        if let current = appState.bookInMemory(uniqueId: book.uniqueId) {
            return current
        }
        // Outside the in-memory window the reader's saves and conflict choices would have nothing to mutate.
        if let stored = await appState.bookStore.book(uniqueId: book.uniqueId) {
            appState.hotCache.insert(stored)
            return stored
        }
        return book
    }

    private func cancelCurrentRequest(removeActivity: Bool) {
        if let book = activity?.book {
            downloads.cancelReaderAssetPreparation(for: book)
        }
        requestTask?.cancel()
        requestTask = nil
        requestedBookID = nil
        if removeActivity {
            activity = nil
        }
    }
}
