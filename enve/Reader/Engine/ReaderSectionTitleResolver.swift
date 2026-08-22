import Foundation
@preconcurrency import ReadiumShared

@MainActor
final class ReaderSectionTitleResolver {
    private var lastLookupKey: String?
    private var lookupTask: Task<Void, Never>?
    private var generation = 0

    deinit {
        lookupTask?.cancel()
    }

    func scheduleLookup(
        key: String,
        locator: Locator,
        fallbackTitle: String?,
        resolveVisibleTitle: @MainActor @escaping (Locator) async -> String?,
        apply: @MainActor @escaping (String?) -> Void
    ) {
        guard key != lastLookupKey else { return }
        lastLookupKey = key
        generation += 1
        let scheduledGeneration = generation

        lookupTask?.cancel()
        lookupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let domTitle = await resolveVisibleTitle(locator)
            guard !Task.isCancelled, generation == scheduledGeneration else { return }
            apply(domTitle ?? fallbackTitle)
        }
    }
}
