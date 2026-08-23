import Foundation
@preconcurrency import ReadiumShared

@MainActor
final class ReaderLocationPipeline {
    struct Update {
        let progression: Double
        let previousProgression: Double
        let previousChapterIndex: Int?
        let newChapterIndex: Int?
        let shouldPublishProgress: Bool
    }

    private(set) var latestObservedProgression: Double?
    private var lastEnhancedResourcePath: String?
    private var lastStatsRecordedProgression: Double?
    private var lastStatsRecordedAt: Date = .distantPast

    func reset(initialProgression: Double?) {
        latestObservedProgression = initialProgression
        lastEnhancedResourcePath = nil
        lastStatsRecordedProgression = nil
        lastStatsRecordedAt = .distantPast
    }

    func observe(
        locator: Locator,
        locatorProgress: ReaderLocatorProgress,
        fallbackProgress: Double?,
        publishedProgress: Double?,
        chapterIndex: (Double?) -> Int?
    ) -> Update {
        let previousProgression = latestObservedProgression ?? publishedProgress ?? 0
        let previousPublishedProgression = publishedProgress ?? previousProgression
        let previousChapterIndex = chapterIndex(previousPublishedProgression)
        let progression = locatorProgress.update(locator: locator, fallbackProgress: fallbackProgress)
        latestObservedProgression = progression
        let newChapterIndex = chapterIndex(progression)
        let shouldPublishProgress =
            abs(progression - previousPublishedProgression) >= 0.002
            || newChapterIndex != previousChapterIndex
            || progression <= 0.001
            || progression >= 0.999

        return Update(
            progression: progression,
            previousProgression: previousProgression,
            previousChapterIndex: previousChapterIndex,
            newChapterIndex: newChapterIndex,
            shouldPublishProgress: shouldPublishProgress
        )
    }

    func shouldEnhanceResource(path: String) -> Bool {
        guard lastEnhancedResourcePath != path else { return false }
        lastEnhancedResourcePath = path
        return true
    }

    func shouldRecordStats(progression: Double, now: Date = Date()) -> Bool {
        let shouldRecord =
            lastStatsRecordedProgression.map { abs(progression - $0) >= 0.0025 } ?? true
            || now.timeIntervalSince(lastStatsRecordedAt) >= 2.5
            || progression >= 0.99
        if shouldRecord {
            lastStatsRecordedProgression = progression
            lastStatsRecordedAt = now
        }
        return shouldRecord
    }
}
