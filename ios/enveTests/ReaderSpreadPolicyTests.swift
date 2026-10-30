import CoreGraphics
import Testing

@testable import enve

struct ReaderSpreadPolicyTests {
    private let unfoldedLandscape = CGSize(width: 951, height: 669)
    private let unfoldedPortrait = CGSize(width: 669, height: 951)
    private let phoneLandscape = CGSize(width: 852, height: 393)

    private func showsSpine(
        canvas: CGSize,
        columnMode: ReaderColumnOption = .auto,
        scrollEnabled: Bool = false,
        isFixedLayout: Bool = false,
        usesAccessibilityType: Bool = false
    ) -> Bool {
        ReaderSpreadPolicy.showsSpine(
            canvas: canvas,
            columnMode: columnMode,
            scrollEnabled: scrollEnabled,
            isFixedLayout: isFixedLayout,
            usesAccessibilityType: usesAccessibilityType
        )
    }

    @Test func bookShapedCanvasSpreadsAutomaticColumns() {
        #expect(showsSpine(canvas: unfoldedLandscape))
    }

    @Test func tallCanvasesStaySinglePage() {
        #expect(!showsSpine(canvas: unfoldedPortrait))
        #expect(!showsSpine(canvas: unfoldedPortrait, columnMode: .two))
    }

    @Test func shortLandscapePhonesKeepTheirLayout() {
        #expect(!showsSpine(canvas: phoneLandscape))
        // An explicit two-column choice on a narrow phone is left to ReadiumCSS's own width rule.
        #expect(!showsSpine(canvas: phoneLandscape, columnMode: .two))
    }

    // The spine and the engine's spread request travel together: an explicit two-column choice on a
    // book-shaped canvas gets the same two columns as the automatic mode, never a gutter over one.
    @Test func explicitColumnChoicesAreRespected() {
        #expect(!showsSpine(canvas: unfoldedLandscape, columnMode: .one))
        #expect(showsSpine(canvas: unfoldedLandscape, columnMode: .two))
    }

    @Test func scrollingFixedLayoutAndAccessibilityTextNeverSpread() {
        #expect(!showsSpine(canvas: unfoldedLandscape, scrollEnabled: true))
        #expect(!showsSpine(canvas: unfoldedLandscape, isFixedLayout: true))
        #expect(!showsSpine(canvas: unfoldedLandscape, usesAccessibilityType: true))
        #expect(!showsSpine(canvas: unfoldedLandscape, columnMode: .two, usesAccessibilityType: true))
    }

    private let horizontalFold = FoldLine(axis: .horizontal, center: 475.5, clearance: 40.5, isActive: true)

    @Test func lecternSplitsThePageFromTheControlsAtTheFold() {
        let halves = ReaderSpreadPolicy.lecternHalves(canvas: unfoldedPortrait, pose: .tabletop, fold: horizontalFold)
        #expect(halves == FoldLine.Halves(upperHeight: 435, foldCenter: 475.5, lowerTop: 516, lowerHeight: 435))
    }

    @Test func anOffCentreFoldMovesTheLecternWithIt() {
        let fold = FoldLine(axis: .horizontal, center: 600, clearance: 20, isActive: true)
        let halves = ReaderSpreadPolicy.lecternHalves(canvas: unfoldedPortrait, pose: .tabletop, fold: fold)
        #expect(halves?.upperHeight == 580)
        #expect(halves?.lowerTop == 620)
        #expect(halves?.lowerHeight == 331)
    }

    // A window on one side of the hinge reports no fold and reads as a single page however the device is held.
    @Test func theLecternNeedsTheTabletopPoseAndAHorizontalFold() {
        #expect(ReaderSpreadPolicy.lecternHalves(canvas: unfoldedPortrait, pose: .tabletop, fold: nil) == nil)
        #expect(ReaderSpreadPolicy.lecternHalves(canvas: unfoldedPortrait, pose: .flat, fold: horizontalFold) == nil)
        #expect(ReaderSpreadPolicy.lecternHalves(canvas: unfoldedLandscape, pose: .book, fold: horizontalFold) == nil)
        let verticalFold = FoldLine(axis: .vertical, center: 334.5, clearance: 40.5, isActive: true)
        #expect(ReaderSpreadPolicy.lecternHalves(canvas: unfoldedPortrait, pose: .tabletop, fold: verticalFold) == nil)
    }
}
