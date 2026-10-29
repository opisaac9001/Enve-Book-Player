import Foundation
import Testing

@testable import enve

@MainActor
struct ReaderPinchResizeTests {
    @Test func boundsMatchTheAppearanceOwnerAndTheTrayStep() throws {
        let decoder = JSONDecoder()
        let large = try decoder.decode(ClassicReaderAppearance.self, from: Data(#"{"fontSize": 9}"#.utf8))
        let small = try decoder.decode(ClassicReaderAppearance.self, from: Data(#"{"fontSize": 0.1}"#.utf8))

        #expect(large.fontSize == ReaderPinchResize.maximumFontSize)
        #expect(small.fontSize == ReaderPinchResize.minimumFontSize)
        #expect(ReaderPinchResize.step == 0.1)
        #expect(ReaderPinchResize.snap(ClassicReaderAppearance().fontSize) == ClassicReaderAppearance().fontSize)
    }

    @Test func snapLandsOnTheNearerStepperPosition() {
        #expect(ReaderPinchResize.snap(1.04) == 1.0)
        #expect(ReaderPinchResize.snap(1.06) == 1.1)
        #expect(ReaderPinchResize.snap(2.33) == 2.3)
        #expect(ReaderPinchResize.snap(2.37) == 2.4)
    }

    @Test func snapNeverLeavesTheRange() {
        #expect(ReaderPinchResize.snap(-1) == ReaderPinchResize.minimumFontSize)
        #expect(ReaderPinchResize.snap(0) == ReaderPinchResize.minimumFontSize)
        #expect(ReaderPinchResize.snap(7) == ReaderPinchResize.maximumFontSize)
    }

    @Test func everyStepperPositionRoundTrips() {
        for index in 0...25 {
            let size = ((ReaderPinchResize.minimumFontSize + Double(index) * ReaderPinchResize.step) * 10).rounded() / 10
            #expect(ReaderPinchResize.snap(size) == size)
        }
    }

    @Test func restingFingersAskForNothing() {
        #expect(ReaderPinchResize.target(startSize: 1.0, scale: 1.0) == nil)
        #expect(ReaderPinchResize.target(startSize: 1.0, scale: 1.05) == nil)
        #expect(ReaderPinchResize.target(startSize: 1.0, scale: 0.95) == nil)
        #expect(ReaderPinchResize.target(startSize: 1.0, scale: 1 + ReaderPinchResize.deadZone) != nil)
    }

    @Test func spreadingGrowsAndPinchingShrinks() {
        #expect(ReaderPinchResize.target(startSize: 1.0, scale: 1.5) == 1.5)
        #expect(ReaderPinchResize.target(startSize: 1.0, scale: 0.6) == 0.6)
        #expect(ReaderPinchResize.target(startSize: 1.2, scale: 1.25) == 1.5)
    }

    @Test func targetNeverLeavesTheRange() {
        #expect(ReaderPinchResize.target(startSize: 2.0, scale: 10) == ReaderPinchResize.maximumFontSize)
        #expect(ReaderPinchResize.target(startSize: 0.8, scale: 0.01) == ReaderPinchResize.minimumFontSize)
    }

    @Test func fingersBackWhereTheyStartedAskForNothing() {
        #expect(ReaderPinchResize.target(startSize: 1.2, scale: 1.8) == 2.2)
        #expect(ReaderPinchResize.target(startSize: 1.2, scale: 1.0) == nil)
    }

    @Test func degenerateScalesAskForNothing() {
        #expect(ReaderPinchResize.target(startSize: 1.0, scale: 0) == nil)
        #expect(ReaderPinchResize.target(startSize: 1.0, scale: -1) == nil)
        #expect(ReaderPinchResize.target(startSize: 1.0, scale: .nan) == nil)
        #expect(ReaderPinchResize.target(startSize: 1.0, scale: .infinity) == nil)
    }

    @Test func percentLabelRoundsToWholePercent() {
        #expect(ReaderPinchResize.percentLabel(1.0) == "100%")
        #expect(ReaderPinchResize.percentLabel(1.25) == "125%")
        #expect(ReaderPinchResize.percentLabel(0.5) == "50%")
    }

    @Test func tapGuardOutlivesTheLiftingFingers() {
        #expect(ReaderPinchResize.tapGuard > 0.1)
        #expect(ReaderPinchResize.tapGuard < 1)
    }
}
