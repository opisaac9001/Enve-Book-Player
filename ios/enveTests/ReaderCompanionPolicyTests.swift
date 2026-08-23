import Foundation
import ReadiumNavigator
import Testing

@testable import enve

struct ReaderCompanionPolicyTests {
    @Test func columnOverrideOnlyAppliesToWideReceivers() {
        #expect(ReaderCompanionLayoutPolicy.columnCount(forAspectRatio: 16.0 / 9.0) == .two)
        #expect(ReaderCompanionLayoutPolicy.columnCount(forAspectRatio: 1.2) == nil)
        #expect(ReaderCompanionLayoutPolicy.columnCount(forAspectRatio: 0.75) == nil)
    }

    @Test func castingCanvasIsClampedToTheWidestSupportedAspect() {
        #expect(ReaderCompanionLayoutPolicy.canvasSize(forAspectRatio: 1.0) == nil)
        #expect(ReaderCompanionLayoutPolicy.canvasSize(forAspectRatio: 16.0 / 9.0) == CGSize(width: 960, height: 540))
        #expect(ReaderCompanionLayoutPolicy.canvasSize(forAspectRatio: 4.0) == CGSize(width: 1296, height: 540))
    }

    @Test func pageIndexNeverGoesNegativeAndTreatsAnUncountedBookAsOnePage() {
        #expect(ReaderCompanionLayoutPolicy.pageIndex(progress: nil, totalPages: 300) == 0)
        #expect(ReaderCompanionLayoutPolicy.pageIndex(progress: 0.5, totalPages: 300) == 150)
        #expect(ReaderCompanionLayoutPolicy.pageIndex(progress: 0.99, totalPages: 0) == 0)
        #expect(ReaderCompanionLayoutPolicy.broadcastTotalPages(0) == 1)
    }

    @MainActor
    @Test func highlightBroadcastsAreThrottled() {
        let session = ReaderCompanionSnapshot()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(session.shouldBroadcastHighlight(now: start))
        #expect(!session.shouldBroadcastHighlight(now: start.addingTimeInterval(0.3)))
        #expect(session.shouldBroadcastHighlight(now: start.addingTimeInterval(0.45)))
        #expect(!session.shouldBroadcastHighlight(now: start.addingTimeInterval(0.6)))
    }

    @MainActor
    @Test func sessionActivationNotifiesOnlyOnTransitions() {
        let session = ReaderCompanionSnapshot()
        var notifications = 0
        session.onChange = { notifications += 1 }

        session.isActive = true
        session.isActive = true
        session.isActive = false

        #expect(notifications == 2)
    }
}
