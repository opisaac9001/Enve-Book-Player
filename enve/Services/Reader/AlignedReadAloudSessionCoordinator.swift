import Foundation

@MainActor
final class AlignedReadAloudSessionCoordinator {
    static let shared = AlignedReadAloudSessionCoordinator()

    private var preparationTask: Task<Void, Never>?
    private var generation = 0
    private let preparationReporter: any PlaybackPreparationReporting

    private init(preparationReporter: any PlaybackPreparationReporting = ActivePlayback.composition.preparationReporter) {
        self.preparationReporter = preparationReporter
    }

    func play(_ book: Book, presentPlayer: Bool = true) {
        #if os(tvOS)
        preparationReporter.endPreparation(
            errorDescription: "Read-aloud books play on iPhone or iPad. Use Read Together to mirror them here."
        )
        #else
        LastOpenedBookStore.shared.record(book)
        cancel()
        let requestGeneration = generation
        preparationReporter.beginPreparation()

        preparationTask = Task { @MainActor in
            do {
                if book.source == .storyteller,
                    LocalEbookImporter.shared.resolveEbookForOverlay(book: book) == nil
                {
                    _ = try await UnifiedDownloadService.shared.ensureStorytellerReadaloudCached(for: book)
                }
                try Task.checkCancellation()
                guard requestGeneration == generation else { return }
                let current = AppState.shared.bookInMemory(uniqueId: book.uniqueId) ?? book
                try await MediaOverlayPlaybackService.shared.play(current, presentPlayer: presentPlayer)
                guard requestGeneration == generation else { return }
                preparationTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard requestGeneration == generation else { return }
                preparationReporter.endPreparation(
                    errorDescription: "Unable to play this read-aloud book: \(error.localizedDescription)"
                )
                preparationTask = nil
            }
        }
        #endif
    }

    func cancel() {
        generation += 1
        preparationTask?.cancel()
        preparationTask = nil
    }
}
