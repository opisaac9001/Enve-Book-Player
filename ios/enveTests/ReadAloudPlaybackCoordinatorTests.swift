import Foundation
import Testing

@testable import enve

@MainActor
struct ReadAloudPlaybackCoordinatorTests {
    private func clip(
        _ fragmentId: String,
        href: String,
        begin: TimeInterval,
        end: TimeInterval,
        granularity: OverlayGranularity = .unspecified,
        parentGroupIndex: Int? = nil
    ) -> AudioOverlayClip {
        AudioOverlayClip(
            fragmentId: fragmentId,
            textHref: href,
            audioSrc: "audio/\(href).mp3",
            clipBegin: begin,
            clipEnd: end,
            granularity: granularity,
            parentGroupIndex: parentGroupIndex
        )
    }

    private func loaded(_ clips: [AudioOverlayClip]) -> ReadAloudPlaybackCoordinator {
        let coordinator = ReadAloudPlaybackCoordinator()
        coordinator.publishMapping(
            clips: clips,
            timeline: MediaOverlayTimeline(clips: clips),
            chapterDurations: ["ch1.xhtml": 30]
        )
        return coordinator
    }

    private var sampleClips: [AudioOverlayClip] {
        [
            clip("s1", href: "ch1.xhtml", begin: 0, end: 4),
            clip("s2", href: "ch1.xhtml", begin: 4, end: 10),
            clip("s3", href: "ch2.xhtml", begin: 0, end: 6),
            clip("s1", href: "ch2.xhtml", begin: 6, end: 9),
        ]
    }

    @Test func mappingIndexesFragmentsChaptersAndRemainingTime() {
        let coordinator = loaded(sampleClips)

        #expect(coordinator.orderedOverlayChapterHrefs == ["ch1.xhtml", "ch2.xhtml"])
        #expect(coordinator.overlayClipFragmentSet == ["s1", "s2", "s3"])
        #expect(coordinator.overlayClipIndexMap["s1"] == 0)
        #expect(coordinator.overlayRemainingChapterSecondsByClipIndex == [10, 6, 9, 3])
        #expect(coordinator.overlayRemainingBookSecondsByClipIndex == [19, 15, 9, 3])
        #expect(coordinator.overlayChapterStartSecondsByHref["ch2.xhtml"] == 10)
        #expect(coordinator.overlayChapterEndSecondsByHref["ch1.xhtml"] == 10)
        #expect(coordinator.overlayChapterDurations["ch1.xhtml"] == 30)
    }

    @Test func bestClipIndexPrefersTheHrefOfTheVisibleDocument() {
        let coordinator = loaded(sampleClips)

        #expect(coordinator.bestClipIndex(for: "s1", preferredHref: "ch2.xhtml") == 3)
        #expect(coordinator.bestClipIndex(for: "s1", preferredHref: "OPS/ch1.xhtml") == 0)
        #expect(coordinator.bestClipIndex(for: "s2", preferredHref: nil) == 1)
        #expect(coordinator.bestClipIndex(for: "missing", preferredHref: nil) == nil)
    }

    @Test func bestClipIndexFallsBackToTheFirstCandidateWithoutAPlayer() {
        let coordinator = loaded(sampleClips)

        #expect(coordinator.bestClipIndex(for: "s1", preferredHref: nil) == 0)
        #expect(coordinator.bestClipIndex(for: "s1", preferredHref: "") == 0)
        #expect(coordinator.playingClipIndex() == nil)
    }

    @Test func siblingClipsGroupSentenceWordsWithinOneDocument() {
        let clips = [
            clip("w1", href: "ch1.xhtml", begin: 0, end: 1, granularity: .small, parentGroupIndex: 0),
            clip("w2", href: "ch1.xhtml", begin: 1, end: 2, granularity: .small, parentGroupIndex: 0),
            clip("w3", href: "ch1.xhtml", begin: 2, end: 3, granularity: .small, parentGroupIndex: 1),
            clip("w1", href: "ch2.xhtml", begin: 3, end: 4, granularity: .small, parentGroupIndex: 0),
        ]
        let coordinator = loaded(clips)

        #expect(coordinator.siblingClips(groupIndex: 0, textHref: "ch1.xhtml").map(\.fragmentId) == ["w1", "w2"])
        #expect(coordinator.siblingClips(groupIndex: 1, textHref: "ch1.xhtml").map(\.fragmentId) == ["w3"])
        #expect(coordinator.siblingClips(groupIndex: 2, textHref: "ch1.xhtml").isEmpty)
    }

    @Test func pageFollowWorkIsThrottledToOneCheckPerInterval() {
        let coordinator = loaded(sampleClips)

        #expect(coordinator.shouldRunPageFollowWork(now: 100) == true)
        #expect(coordinator.shouldRunPageFollowWork(now: 100.2) == false)
        #expect(coordinator.shouldRunPageFollowWork(now: 100.4) == true)
    }

    @Test func overlayDecorationSkipsRepeatsAndRapidReapplication() {
        let coordinator = loaded(sampleClips)

        #expect(coordinator.shouldApplyOverlayDecoration(key: "clip|ch1.xhtml|s1", now: 10) == true)
        #expect(coordinator.shouldApplyOverlayDecoration(key: "clip|ch1.xhtml|s1", now: 11) == false)
        #expect(coordinator.shouldApplyOverlayDecoration(key: "clip|ch1.xhtml|s2", now: 10.4) == false)
        #expect(coordinator.shouldApplyOverlayDecoration(key: "clip|ch1.xhtml|s2", now: 10.6) == true)
    }

    @Test func remappingResetsDecorationThrottleState() {
        let coordinator = loaded(sampleClips)
        #expect(coordinator.shouldApplyOverlayDecoration(key: "clip|ch1.xhtml|s1", now: 10) == true)

        coordinator.publishMapping(clips: sampleClips, timeline: MediaOverlayTimeline(clips: sampleClips))

        #expect(coordinator.shouldApplyOverlayDecoration(key: "clip|ch1.xhtml|s1", now: 10) == true)
    }

    @Test func cleanupClearsMappingAndFollowState() {
        let coordinator = loaded(sampleClips)
        coordinator.isReadAloudMode = true
        coordinator.lastSyncedClipIndex = 2
        coordinator.userDidPageTurn = true
        coordinator.manualNavigationGeneration = 4

        coordinator.resetAfterCleanup()

        #expect(coordinator.overlayClips.isEmpty)
        #expect(coordinator.overlayTimeline == nil)
        #expect(coordinator.overlayClipFragmentSet.isEmpty)
        #expect(coordinator.overlayClipIndexMap.isEmpty)
        #expect(coordinator.orderedOverlayChapterHrefs.isEmpty)
        #expect(coordinator.isReadAloudMode == false)
        #expect(coordinator.lastSyncedClipIndex == -1)
        #expect(coordinator.userDidPageTurn == false)
        #expect(coordinator.manualNavigationGeneration == 0)
        #expect(coordinator.bestClipIndex(for: "s1", preferredHref: nil) == nil)
    }
}
