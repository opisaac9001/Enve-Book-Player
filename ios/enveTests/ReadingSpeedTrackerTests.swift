import Foundation
import Testing
@testable import enve

struct ReadingSpeedTrackerTests {
    @Test func regularReadingProducesAnEstimateAfterWarmup() async {
        let tracker = ReadingSpeedTracker()
        await tracker.recordPageTurn(progress: 0.1, totalPositions: 1000, at: 0)
        for page in 1...3 {
            await tracker.recordPageTurn(progress: 0.1 + Double(page) / 1000, totalPositions: 1000, at: Double(page * 20))
        }
        let rate = await tracker.progressPerMinute
        #expect(abs((rate ?? 0) - 0.003) < 0.000001)
        #expect(await tracker.timeRemaining(from: 0.5) != nil)
    }

    @Test func jumpsFlicksBacktrackingAndIdleDoNotTeachAPace() async {
        let tracker = ReadingSpeedTracker()
        for (progress, time) in [(0.1, 0.0), (0.8, 20), (0.801, 21), (0.5, 40), (0.501, 700)] {
            await tracker.recordPageTurn(progress: progress, totalPositions: 1000, at: time)
        }
        #expect(await tracker.progressPerMinute == nil)
        #expect(await tracker.totals.progress == 0)
        await tracker.recordPageTurn(progress: 0.502, totalPositions: 1000, at: 720)
        #expect(abs(await tracker.totals.progress - 0.001) < 0.000001)
    }

    @Test func backgroundTimeAndInvalidPositionsNeverBecomeSamples() async {
        let tracker = ReadingSpeedTracker()
        await tracker.recordPageTurn(progress: 0.1, totalPositions: 1000, at: 0)
        await tracker.pause()
        await tracker.recordPageTurn(progress: 0.101, totalPositions: 1000, at: 200)
        await tracker.recordPageTurn(progress: .nan, totalPositions: 1000, at: 220)
        await tracker.recordPageTurn(progress: 0.102, totalPositions: 1000, at: 240)
        #expect(await tracker.totals.seconds == 0)
    }

    @Test func unusualSampleCannotDominateAnEstablishedEstimate() async {
        let tracker = ReadingSpeedTracker()
        for page in 0...3 {
            await tracker.recordPageTurn(progress: 0.1 + Double(page) / 1000, totalPositions: 1000, at: Double(page * 20))
        }
        await tracker.recordPageTurn(progress: 0.104, totalPositions: 1000, at: 560)
        #expect(abs(await tracker.totals.seconds - 100) < 0.000001)
        #expect(await tracker.timeRemaining(from: .nan) == nil)
    }
}
