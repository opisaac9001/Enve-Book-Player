import SwiftUI

enum HearthAdaptive {
    // Regular-width containers such as iPad columns and unfolded foldables start around 600pt. Compact
    // iPhone portrait layouts stop near 440pt and iPhone landscape already clears this, so ordinary
    // iPhone layouts keep their existing column counts.
    static let wideBreakpoint: CGFloat = 600
    static let readableWidth: CGFloat = 1040
    static let wideReadableWidth: CGFloat = 1080

    static func isWide(_ width: CGFloat) -> Bool {
        width >= wideBreakpoint
    }

    static func contentWidth(for width: CGFloat, maximum: CGFloat = readableWidth) -> CGFloat {
        min(width, maximum)
    }

    static func horizontalPadding(for width: CGFloat) -> CGFloat {
        isWide(width) ? 32 : 24
    }

    static func gridColumns(width: CGFloat, minimum: CGFloat, maximum: Int = 8, compactFallback: Int) -> [GridItem] {
        if !isWide(width) {
            return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: compactFallback)
        }
        let available = max(width - horizontalPadding(for: width) * 2, minimum)
        let count = max(compactFallback, min(maximum, Int((available / minimum).rounded(.down))))
        return Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: count)
    }

    // Preferences the library's cover-size cycle may step through; `bookGridCount` honours every value in it.
    static func displayCycleRange(for width: CGFloat) -> ClosedRange<Int> {
        isWide(width) ? 5...12 : 2...4
    }

    static func bookGridCount(width: CGFloat, preferred: Int) -> Int {
        guard isWide(width) else {
            let compact = preferred > 0 ? preferred : 3
            return max(2, min(compact, 4))
        }
        let available = max(width - horizontalPadding(for: width) * 2, 320)
        let adaptive = Int((available / 112).rounded(.down))
        let wide = preferred >= 4 ? preferred : adaptive
        return max(5, min(wide, 12))
    }
}

extension View {
    func hearthReadableFrame(width: CGFloat, maximum: CGFloat = HearthAdaptive.readableWidth) -> some View {
        frame(width: HearthAdaptive.contentWidth(for: width, maximum: maximum), alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}
