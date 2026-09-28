import Foundation
import Testing

@testable import enve

struct ReaderRestClockTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func countsOnlyForegroundReading() {
        var clock = ReaderRestClock()
        clock.restart(at: start)
        clock.pause(at: start.addingTimeInterval(600))
        clock.resume(at: start.addingTimeInterval(660))

        #expect(clock.elapsed(at: start.addingTimeInterval(960)) == 900)
    }

    @Test func longBreakCountsAsRest() {
        var clock = ReaderRestClock()
        clock.restart(at: start)
        clock.pause(at: start.addingTimeInterval(1_200))

        let rested = clock.resume(at: start.addingTimeInterval(1_200 + ReaderRestClock.restingGap))

        #expect(rested)
        #expect(clock.elapsed(at: start.addingTimeInterval(1_200 + ReaderRestClock.restingGap + 30)) == 30)
    }

    @Test func shortBreakKeepsReadingTime() {
        var clock = ReaderRestClock()
        clock.restart(at: start)
        clock.pause(at: start.addingTimeInterval(300))

        let rested = clock.resume(at: start.addingTimeInterval(360))

        #expect(!rested)
        #expect(clock.elapsed(at: start.addingTimeInterval(360)) == 300)
    }

    @Test func pausedClockDoesNotAdvance() {
        var clock = ReaderRestClock()
        clock.restart(at: start)
        clock.pause(at: start.addingTimeInterval(120))

        #expect(!clock.isRunning)
        #expect(clock.elapsed(at: start.addingTimeInterval(10_000)) == 120)
    }

    @Test func restartClearsReadingTime() {
        var clock = ReaderRestClock()
        clock.restart(at: start)
        clock.restart(at: start.addingTimeInterval(1_800))

        #expect(clock.isRunning)
        #expect(clock.elapsed(at: start.addingTimeInterval(1_830)) == 30)
    }
}
