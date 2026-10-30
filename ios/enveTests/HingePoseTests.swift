import CoreGraphics
import Testing

@testable import enve

struct HingePoseTests {
    private let portrait = CGSize(width: 669, height: 951)
    private let landscape = CGSize(width: 951, height: 669)

    @Test(arguments: [HingeStateStore.Status.unavailable, .unknown, .closed, .fullyOpen])
    func onlyAPartlyOpenHingeChangesThePose(_ status: HingeStateStore.Status) {
        #expect(HingePose.resolve(status: status, canvas: portrait) == .flat)
        #expect(HingePose.resolve(status: status, canvas: landscape) == .flat)
    }

    @Test func partlyOpenPortraitIsTabletop() {
        #expect(HingePose.resolve(status: .partiallyOpen, canvas: portrait) == .tabletop)
    }

    @Test func partlyOpenLandscapeIsBook() {
        #expect(HingePose.resolve(status: .partiallyOpen, canvas: landscape) == .book)
    }

    @Test func anUnmeasuredCanvasIsFlat() {
        #expect(HingePose.resolve(status: .partiallyOpen, canvas: .zero) == .flat)
    }
}
