import CoreGraphics
import Testing

@testable import enve

struct PlayerLayoutPolicyTests {
    @Test(arguments: [
        CGSize(width: 393, height: 852),
        CGSize(width: 466, height: 678),
        CGSize(width: 669, height: 951),
        CGSize(width: 744, height: 1133),
    ])
    func tallCanvasesStackThePlayer(_ size: CGSize) {
        #expect(PlayerLayoutPolicy.arrangement(for: size, usesAccessibilityType: false) == .stacked)
    }

    @Test(arguments: [
        CGSize(width: 852, height: 393),
        CGSize(width: 667, height: 375),
        CGSize(width: 951, height: 669),
        CGSize(width: 1194, height: 834),
    ])
    func wideShortCanvasesPlaceControlsBesideTheCover(_ size: CGSize) {
        #expect(PlayerLayoutPolicy.arrangement(for: size, usesAccessibilityType: false) == .sideBySide)
    }

    private let uprightCanvas = CGSize(width: 669, height: 951)
    private let centredFold = FoldLine(axis: .horizontal, center: 475.5, clearance: 40.5, isActive: true)
    private let offCentreFold = FoldLine(axis: .horizontal, center: 420, clearance: 30, isActive: true)

    private func uprightArrangement(pose: HingePose, fold: FoldLine?) -> PlayerLayoutPolicy.Arrangement {
        PlayerLayoutPolicy.arrangement(for: uprightCanvas, usesAccessibilityType: false, pose: pose, fold: fold)
    }

    private func nightstandHalves(_ arrangement: PlayerLayoutPolicy.Arrangement) -> FoldLine.Halves? {
        if case .nightstand(let halves) = arrangement { halves } else { nil }
    }

    @Test func accessibilityTypeAlwaysStacks() {
        let size = CGSize(width: 951, height: 669)
        #expect(PlayerLayoutPolicy.arrangement(for: size, usesAccessibilityType: true) == .stacked)
        #expect(PlayerLayoutPolicy.arrangement(for: uprightCanvas, usesAccessibilityType: true, pose: .tabletop, fold: centredFold) == .stacked)
    }

    @Test func aProppedDeviceWithAFoldAcrossTheCanvasBecomesANightstand() {
        let halves = FoldLine.Halves(upperHeight: 435, foldCenter: 475.5, lowerTop: 516, lowerHeight: 435)
        #expect(uprightArrangement(pose: .tabletop, fold: centredFold) == .nightstand(halves))
        #expect(uprightArrangement(pose: .flat, fold: centredFold) == .stacked)
    }

    // A window on one side of the hinge has no fold, so the tabletop pose alone never splits it.
    @Test func theTabletopPoseWithoutAHorizontalFoldKeepsTheOrdinaryLayouts() {
        #expect(uprightArrangement(pose: .tabletop, fold: nil) == .stacked)
        let verticalFold = FoldLine(axis: .vertical, center: 334.5, clearance: 40.5, isActive: true)
        #expect(uprightArrangement(pose: .tabletop, fold: verticalFold) == .stacked)
        let wide = CGSize(width: 951, height: 669)
        #expect(PlayerLayoutPolicy.arrangement(for: wide, usesAccessibilityType: false, pose: .tabletop, fold: nil) == .sideBySide)
    }

    @Test func anOffCentreFoldSplitsTheNightstandWhereItCrosses() throws {
        let halves = try #require(nightstandHalves(uprightArrangement(pose: .tabletop, fold: offCentreFold)))
        #expect(halves.upperHeight == 390)
        #expect(halves.foldCenter == 420)
        #expect(halves.lowerTop == 450)
        #expect(halves.lowerHeight == 501)
    }

    @Test func theNightstandCoverFitsTheUprightAreaAboveTheFold() throws {
        for fold in [centredFold, offCentreFold] {
            let arrangement = uprightArrangement(pose: .tabletop, fold: fold)
            let halves = try #require(nightstandHalves(arrangement))
            for ratio: CGFloat in [1, 1.5] {
                let width = PlayerLayoutPolicy.coverWidth(
                    for: uprightCanvas,
                    arrangement: arrangement,
                    coverRatio: ratio,
                    usesAccessibilityType: false,
                    showsError: false
                )
                #expect(width * ratio + PlayerLayoutPolicy.nightstandTitleAllowance <= halves.upperHeight + 0.001)
                #expect(width >= 96)
            }
        }
    }

    @Test func aBookPoseKeepsTheSideBySideLayout() {
        let size = CGSize(width: 951, height: 669)
        let bookFold = FoldLine(axis: .vertical, center: 475.5, clearance: 40.5, isActive: true)
        #expect(PlayerLayoutPolicy.arrangement(for: size, usesAccessibilityType: false, pose: .book, fold: bookFold) == .sideBySide)
    }

    @Test(arguments: [
        CGSize(width: 852, height: 393),
        CGSize(width: 667, height: 375),
        CGSize(width: 951, height: 669),
    ])
    func sideBySideCoverLeavesRoomForTheTitleBlock(_ size: CGSize) {
        for ratio: CGFloat in [1, 1.5] {
            let width = PlayerLayoutPolicy.coverWidth(
                for: size,
                arrangement: .sideBySide,
                coverRatio: ratio,
                usesAccessibilityType: false,
                showsError: false
            )
            #expect(width * ratio <= size.height * 0.56 + 0.001)
            #expect(width <= size.width * 0.38 + 0.001)
            #expect(width >= 120)
        }
    }

    // A folding phone's facing page and outer display are shorter than any phone; the cover gives way
    // before the transport does.
    @Test(arguments: [
        CGSize(width: 391, height: 635),
        CGSize(width: 466, height: 644),
        CGSize(width: 466, height: 678),
    ])
    func stackedCoverLeavesRoomForTheTransportOnShortCanvases(_ size: CGSize) {
        for ratio: CGFloat in [1, 1.5] {
            let width = PlayerLayoutPolicy.coverWidth(for: size, arrangement: .stacked, coverRatio: ratio, usesAccessibilityType: false, showsError: false)
            #expect(width * ratio + PlayerLayoutPolicy.stackedChromeHeight <= size.height + 0.001)
            #expect(width >= 96)
        }
    }

    @Test func stackedCoverMatchesTheEstablishedPhoneSizing() {
        let size = CGSize(width: 393, height: 852)
        let width = PlayerLayoutPolicy.coverWidth(
            for: size,
            arrangement: .stacked,
            coverRatio: 1,
            usesAccessibilityType: false,
            showsError: false
        )
        #expect(width == min(size.width * 0.78, size.height * 0.42))
    }
}
