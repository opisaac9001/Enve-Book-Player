import CoreGraphics
import SwiftUI
import Testing

@testable import enve

struct DuoShellLayoutTests {
    private let verticalFold = FoldLine(axis: .vertical, center: 475.5, clearance: 40.5, isActive: false)
    private let horizontalFold = FoldLine(axis: .horizontal, center: 475.5, clearance: 40.5, isActive: true)
    private let column = SideColumn(width: 84, statusBarBottom: 120)

    private func resolve(
        fold: FoldLine? = nil,
        column: SideColumn? = nil,
        pose: HingePose = .flat,
        hingeKnown: Bool = true,
        width: UserInterfaceSizeClass? = .regular,
        accessibility: Bool = false
    ) -> DuoShellLayout {
        DuoShellLayout.resolve(
            fold: fold,
            column: column,
            pose: pose,
            hingeKnown: hingeKnown,
            horizontalSizeClass: width,
            usesAccessibilityType: accessibility
        )
    }

    @Test func withoutAFoldOrAColumnTheShellStaysStandard() {
        #expect(resolve() == .standard)
        #expect(resolve(pose: .tabletop) == .standard)
    }

    @Test func aVerticalFoldBesideTheColumnSpreads() {
        #expect(resolve(fold: verticalFold, column: column) == .spread(verticalFold, column))
        #expect(resolve(fold: verticalFold, column: column, pose: .book) == .spread(verticalFold, column))
    }

    @Test func aSpreadNeedsRegularWidthAndTheColumn() {
        #expect(resolve(fold: verticalFold, column: column, width: .compact) == .standard)
        #expect(resolve(fold: verticalFold, column: nil) == .standard)
    }

    @Test func aHorizontalFoldBecomesANightstandOnlyWhenPropped() {
        #expect(resolve(fold: horizontalFold, pose: .tabletop) == .nightstand(horizontalFold))
        #expect(resolve(fold: horizontalFold, pose: .flat) == .standard)
    }

    // Closed, the column alone marks the outer display; a landscape phone with a wide notch inset has no hinge.
    @Test func aColumnWithoutAFoldOnACompactCanvasIsThePocket() {
        #expect(resolve(column: column, width: .compact) == .pocket(column))
        #expect(resolve(column: column, hingeKnown: false, width: .compact) == .standard)
        #expect(resolve(column: column, width: .regular) == .standard)
    }

    @Test func accessibilityTypeKeepsTheBottomBar() {
        #expect(resolve(fold: verticalFold, column: column, accessibility: true) == .standard)
        #expect(resolve(fold: horizontalFold, pose: .tabletop, accessibility: true) == .standard)
        #expect(resolve(column: column, width: .compact, accessibility: true) == .standard)
    }

    @Test func theColumnIsTheTrailingInsetWithTheStatusBarInsideIt() {
        let column = SideColumn(
            trailingInset: 84,
            viewWidth: 867,
            occlusions: [CGRect(x: 677, y: 21, width: 59, height: 37), CGRect(x: 867, y: 0, width: 84, height: 120)]
        )
        #expect(column?.width == 84)
        #expect(column?.statusBarBottom == 120)
        #expect(SideColumn(trailingInset: 59, viewWidth: 800, occlusions: []) == nil)
        #expect(SideColumn(trailingInset: 84, viewWidth: 867, occlusions: [])?.statusBarBottom == 0)
    }

    @Test func foldLinesFollowTheLongerSideOfTheRegion() {
        let vertical = FoldLine(
            regionFrame: CGRect(x: 455, y: 0, width: 41, height: 669),
            margins: EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20),
            isActive: false
        )
        #expect(vertical.axis == .vertical)
        #expect(vertical.center == 475.5)
        #expect(vertical.clearance == 40.5)
        #expect(vertical.inset == 0)

        let horizontal = FoldLine(
            regionFrame: CGRect(x: 0, y: 455, width: 669, height: 41),
            margins: EdgeInsets(top: 20, leading: 0, bottom: 20, trailing: 0),
            isActive: true
        )
        #expect(horizontal.axis == .horizontal)
        #expect(horizontal.center == 475.5)
        #expect(horizontal.inset == 40.5)
    }

    @Test func halvesKeepTheHingeClearanceOnlyWhileFolded() {
        #expect(
            horizontalFold.halves(canvasHeight: 951)
                == FoldLine.Halves(upperHeight: 435, foldCenter: 475.5, lowerTop: 516, lowerHeight: 435)
        )
        let flat = FoldLine(axis: .horizontal, center: 475.5, clearance: 40.5, isActive: false)
        #expect(
            flat.halves(canvasHeight: 951)
                == FoldLine.Halves(upperHeight: 475.5, foldCenter: 475.5, lowerTop: 475.5, lowerHeight: 475.5)
        )
        #expect(verticalFold.halves(canvasHeight: 669) == nil)
        #expect(horizontalFold.halves(canvasHeight: 0) == nil)
    }

    // A fold near a window's edge still leaves the lower area measured from the canvas, not from a halfway line.
    @Test func halvesClampToTheCanvasAroundAnOffCentreFold() {
        let fold = FoldLine(axis: .horizontal, center: 20, clearance: 40.5, isActive: true)
        #expect(
            fold.halves(canvasHeight: 500)
                == FoldLine.Halves(upperHeight: 0, foldCenter: 20, lowerTop: 60.5, lowerHeight: 439.5)
        )
    }

    @MainActor
    @Test func spineDeepensAsTheHingeCloses() {
        let store = HingeStateStore()
        #expect(store.spineDepth(flat: 0.35) == 0.35)
        store.noteHinge(status: .fullyOpen, angle: .pi)
        #expect(store.spineDepth(flat: 0.35) == 0.35)
        store.noteHinge(status: .partiallyOpen, angle: .pi / 2)
        #expect(store.spineDepth(flat: 0.35) == 1)
        store.noteHinge(status: .partiallyOpen, angle: .pi * 0.75)
        #expect(abs(store.spineDepth(flat: 0.35) - 0.675) < 0.001)
        store.noteHinge(status: .partiallyOpen, angle: nil)
        #expect(store.spineDepth(flat: 0.35) == 1)
    }
}
