import Testing

@testable import enve

struct ReaderPageTurnTimingTests {
    @Test func delayTracksVisibleSentenceFractionAndPlaybackRate() {
        #expect(
            ReaderPageTurnTiming.delay(
                clipDuration: 8,
                elapsedClipTime: 0,
                visibleRatio: 0.5,
                playbackRate: 1,
                lead: 1
            ) == 3
        )
        #expect(
            ReaderPageTurnTiming.delay(
                clipDuration: 8,
                elapsedClipTime: 0,
                visibleRatio: 0.5,
                playbackRate: 2,
                lead: 1
            ) == 1
        )
    }

    @Test func delayNeverSchedulesBeforeNow() {
        #expect(
            ReaderPageTurnTiming.delay(
                clipDuration: 0.5,
                elapsedClipTime: 0,
                visibleRatio: 0.25,
                playbackRate: 3,
                lead: 1
            ) == 0
        )
    }

    @Test func delayAccountsForElapsedClipTimeWhenRescheduled() {
        #expect(
            ReaderPageTurnTiming.delay(
                clipDuration: 8,
                elapsedClipTime: 2,
                visibleRatio: 0.5,
                playbackRate: 1,
                lead: 1
            ) == 1
        )
    }
}
