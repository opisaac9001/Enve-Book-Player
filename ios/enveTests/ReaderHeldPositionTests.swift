import Foundation
import Testing
@preconcurrency import ReadiumShared
@testable import enve

@MainActor
struct ReaderHeldPositionTests {
    private func locator(_ progress: Double, href: String = "chapter.xhtml") throws -> Locator {
        try Locator(jsonString: "{\"href\":\"\(href)\",\"type\":\"application/xhtml+xml\",\"locations\":{\"totalProgression\":\(progress)}}")
    }

    @Test func delayedMeasurementCannotUndoBackwardNavigation() throws {
        let state = ReaderLocatorProgress()
        _ = state.update(locator: try locator(0.5), fallbackProgress: nil)
        let old = state.measurementGeneration
        state.invalidateMeasurement()
        _ = state.update(locator: try locator(0.2), fallbackProgress: nil)
        #expect(!state.acceptMeasurement("stale", generation: old))
        #expect(state.lastKnownLocator?.locations.totalProgression == 0.2)
    }

    @Test func invalidationKeepsTheLastConfirmedPosition() throws {
        let state = ReaderLocatorProgress()
        _ = state.update(locator: try locator(0.4), fallbackProgress: nil)
        let confirmed = state.lastKnownLocatorJSON
        state.invalidateMeasurement()
        #expect(state.lastKnownLocatorJSON == confirmed)
    }

    @Test func aCommittedLocatorKeepsItsProgressAndAnchorTogether() throws {
        let state = ReaderLocatorProgress()
        _ = state.update(locator: try locator(0.2), fallbackProgress: nil)
        let committed = try locator(0.6, href: "next.xhtml")
        state.updateLocatorJSON(try committed.jsonString())
        #expect(state.lastKnownLocator?.href == committed.href)
        #expect(state.lastKnownLocator?.locations.totalProgression == 0.6)
    }

    @Test func measurementsFromTheSameGenerationCannotOverwriteEachOther() throws {
        let state = ReaderLocatorProgress()
        _ = state.update(locator: try locator(0.4), fallbackProgress: nil)
        let generation = state.measurementGeneration
        #expect(state.acceptMeasurement("first", generation: generation))
        #expect(!state.acceptMeasurement("late", generation: generation))
        #expect(state.lastKnownLocatorJSON == "first")
    }
}
