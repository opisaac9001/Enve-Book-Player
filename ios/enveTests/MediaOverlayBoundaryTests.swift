import Foundation
import Testing

@testable import enve

@Suite @MainActor
struct MediaOverlayBoundaryTests {
    private static func clips(count: Int, audio: String = "a.mp3") -> [AudioOverlayClip] {
        (0..<count).map {
            AudioOverlayClip(
                fragmentId: "f\($0)",
                textHref: "ch.xhtml",
                audioSrc: audio,
                clipBegin: Double($0),
                clipEnd: Double($0) + 1
            )
        }
    }

    @Test func firstGroupWithCurrentClipElsewhereDoesNotReadBeforeTheFirstClip() {
        let clips = Self.clips(count: 6)

        let times = MediaOverlayPlayer.boundaryTimes(
            clips: clips, group: 0...2, currentClipIndex: 4, syncOffset: 0, limit: 160
        )

        #expect(times == [0, 1, 2])
    }

    @Test func laterGroupStartsAtItsOwnClipBegin() {
        let clips = Self.clips(count: 3, audio: "a.mp3") + [
            AudioOverlayClip(fragmentId: "b0", textHref: "ch2.xhtml", audioSrc: "b.mp3", clipBegin: 0.25, clipEnd: 1),
            AudioOverlayClip(fragmentId: "b1", textHref: "ch2.xhtml", audioSrc: "b.mp3", clipBegin: 1, clipEnd: 2),
        ]

        let times = MediaOverlayPlayer.boundaryTimes(
            clips: clips, group: 3...4, currentClipIndex: 0, syncOffset: 0.25, limit: 160
        )

        #expect(times == [0, 0.75])
    }

    @Test func denseGroupsAreCappedFromTheCurrentClip() {
        let clips = Self.clips(count: 500)

        let times = MediaOverlayPlayer.boundaryTimes(
            clips: clips, group: 0...499, currentClipIndex: 100, syncOffset: 0, limit: 160
        )

        #expect(times.count == 160)
        #expect(times.first == 101)
    }

    @Test func lastClipHasNoFurtherBoundaries() {
        let times = MediaOverlayPlayer.boundaryTimes(
            clips: Self.clips(count: 3), group: 0...2, currentClipIndex: 2, syncOffset: 0, limit: 160
        )

        #expect(times.isEmpty)
    }

    @Test func committedTimeStaysInsideTheClipsAudioFile() {
        let clips = [
            AudioOverlayClip(fragmentId: "a", textHref: "ch10.xhtml", audioSrc: "10.mp3", clipBegin: 0, clipEnd: 9),
            AudioOverlayClip(fragmentId: "b", textHref: "ch11.xhtml", audioSrc: "11.mp3", clipBegin: 0, clipEnd: 4),
        ]
        let timeline = MediaOverlayTimeline(clips: clips, audioDurationsBySource: ["10.mp3": 10, "11.mp3": 5])

        #expect(ReaderReadAloudController.committedAudioTime(12, clip: clips[0], clipIndex: 0, timeline: timeline) == 10)
        #expect(ReaderReadAloudController.committedAudioTime(3, clip: clips[1], clipIndex: 1, timeline: timeline) == 10)
        #expect(ReaderReadAloudController.committedAudioTime(12, clip: clips[1], clipIndex: 1, timeline: timeline) == 12)
        #expect(ReaderReadAloudController.committedAudioTime(.nan, clip: clips[1], clipIndex: 1, timeline: timeline) == 10)
    }
}
