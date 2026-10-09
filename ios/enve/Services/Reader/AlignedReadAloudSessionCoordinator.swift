import Foundation

@MainActor
final class AlignedReadAloudSessionCoordinator {
    static let shared = AlignedReadAloudSessionCoordinator(profileSession: .owner)

    private var preparationTask: Task<Void, Never>?
    private var generation = 0
    private let preparationReporter: any PlaybackPreparationReporting

    private unowned let profileSession: ProfileSession

    init(profileSession: ProfileSession, preparationReporter: any PlaybackPreparationReporting = ActivePlayback.composition.preparationReporter) {
        self.profileSession = profileSession
        self.preparationReporter = preparationReporter
    }

    func play(_ book: Book, presentPlayer: Bool = true) {
        #if os(tvOS)
        preparationReporter.endPreparation(
            errorDescription: "Read-aloud books play on iPhone or iPad. Use Read Together to mirror them here."
        )
        #else
        profileSession.lastOpened.record(book)
        cancel()
        let requestGeneration = generation
        preparationReporter.beginPreparation()

        preparationTask = Task { @MainActor in
            do {
                if book.source == .storyteller,
                    profileSession.ebooks.resolveEbookForOverlay(book: book) == nil
                {
                    _ = try await profileSession.downloads.ensureStorytellerReadaloudCached(for: book)
                }
                try Task.checkCancellation()
                guard requestGeneration == generation else { return }
                let current = profileSession.appState.bookInMemory(uniqueId: book.uniqueId) ?? book
                try await profileSession.playback.mediaOverlay.play(current, presentPlayer: presentPlayer)
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

    func retire() async {
        let task = preparationTask
        cancel()
        await task?.value
    }

    func cancel() {
        generation += 1
        preparationTask?.cancel()
        preparationTask = nil
    }
}
