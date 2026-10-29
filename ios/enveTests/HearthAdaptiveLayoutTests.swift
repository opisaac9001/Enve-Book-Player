import CoreGraphics
import SwiftUI
import Testing

@testable import enve

struct HearthAdaptiveLayoutTests {
    @Test func wideLayoutBeginsAtTheBreakpoint() {
        #expect(!HearthAdaptive.isWide(HearthAdaptive.wideBreakpoint - 1))
        #expect(HearthAdaptive.isWide(HearthAdaptive.wideBreakpoint))
    }

    // Column count must never drop as the window grows, otherwise a live resize across the
    // breakpoint shows larger covers on the wider canvas.
    @Test func automaticColumnCountNeverDecreasesAsWidthGrows() {
        var previous = 0
        for width in stride(from: 320, through: 1200, by: 1) {
            let count = HearthAdaptive.bookGridCount(width: CGFloat(width), preferred: 0)
            #expect(count >= previous, "width \(width) produced \(count) after \(previous)")
            previous = count
        }
    }

    @Test(arguments: [320, 393, 430, 466, 599, 600, 669, 744, 951, 1200])
    func automaticColumnsKeepCoversAboveTheMinimumCellWidth(_ width: Int) {
        let width = CGFloat(width)
        let count = HearthAdaptive.bookGridCount(width: width, preferred: 0)
        let spacing: CGFloat = HearthAdaptive.isWide(width) ? 14 : 10
        let padding = HearthAdaptive.horizontalPadding(for: width)
        let cell = (width - padding * 2 - CGFloat(count - 1) * spacing) / CGFloat(count)
        #expect(cell >= 72)
    }

    @Test func compactPreferenceIsClampedToTheCompactRange() {
        #expect(HearthAdaptive.bookGridCount(width: 393, preferred: 1) == 2)
        #expect(HearthAdaptive.bookGridCount(width: 393, preferred: 9) == 4)
    }

    @Test func widePreferenceIsClampedToTheWideRange() {
        #expect(HearthAdaptive.bookGridCount(width: 951, preferred: 3) >= 5)
        #expect(HearthAdaptive.bookGridCount(width: 951, preferred: 40) == 12)
    }

    // The cover-size cycle in the library header steps a preference through this range and
    // switches to the list once the grid reports the top of the range. The grid must therefore
    // honour every preference in the range at the same width, or the cycle never reaches the list.
    @Test(arguments: [320, 393, 466, 560, 599, 600, 669, 951, 1200])
    func displayCycleRangeMatchesTheGridClamp(_ width: Int) {
        let width = CGFloat(width)
        let range = HearthAdaptive.displayCycleRange(for: width)
        for preferred in range {
            #expect(HearthAdaptive.bookGridCount(width: width, preferred: preferred) == preferred)
        }
    }

    @Test func mantelBarIsTallerOnlyWhenBothSizeClassesAreRegular() {
        #expect(MantelBar.classicHeight(horizontal: .compact, vertical: .regular) == MantelBar.phoneHeight)
        #expect(MantelBar.classicHeight(horizontal: .regular, vertical: .compact) == MantelBar.phoneHeight)
        #expect(MantelBar.classicHeight(horizontal: nil, vertical: nil) == MantelBar.phoneHeight)
        #expect(MantelBar.classicHeight(horizontal: .regular, vertical: .regular) == MantelBar.height)
    }
}
