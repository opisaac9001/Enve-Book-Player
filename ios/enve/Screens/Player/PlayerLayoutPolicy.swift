import CoreGraphics

enum PlayerLayoutPolicy {
    enum Arrangement: Equatable {
        case stacked
        case sideBySide
        case nightstand(FoldLine.Halves)
    }

    static let sideBySideMinimumWidth: CGFloat = 600

    static let stackedContentWidth: CGFloat = 600
    static let sideBySideContentWidth: CGFloat = 1040
    static let sideBySideCoverFraction: CGFloat = 0.38

    static let nightstandWideFaceMinimumWidth: CGFloat = 560
    static let nightstandChromeAllowance: CGFloat = 84
    static let nightstandClockAllowance: CGFloat = 96
    static let nightstandWideCoverFraction: CGFloat = 0.44
    static let nightstandNarrowCoverFraction: CGFloat = 0.4

    static func nightstandFaceIsWide(width: CGFloat) -> Bool {
        width >= nightstandWideFaceMinimumWidth
    }

    static func nightstandCoverAllowance(width: CGFloat) -> CGFloat {
        nightstandFaceIsWide(width: width) ? nightstandChromeAllowance : nightstandChromeAllowance + nightstandClockAllowance
    }

    // Reserve chrome height before sizing the cover so short panes retain the transport.
    static let stackedChromeHeight: CGFloat = 470

    static func arrangement(
        for size: CGSize,
        usesAccessibilityType: Bool,
        pose: HingePose = .flat,
        fold: FoldLine? = nil
    ) -> Arrangement {
        guard !usesAccessibilityType else { return .stacked }
        if pose == .tabletop, let halves = fold?.halves(canvasHeight: size.height) {
            return .nightstand(halves)
        }
        return size.width > size.height && size.width >= sideBySideMinimumWidth ? .sideBySide : .stacked
    }

    static func coverWidth(
        for size: CGSize,
        arrangement: Arrangement,
        coverRatio: CGFloat,
        usesAccessibilityType: Bool,
        showsError: Bool
    ) -> CGFloat {
        if usesAccessibilityType {
            return min(size.width * 0.56, 220)
        }
        switch arrangement {
        case .stacked:
            let coverHeight = min(size.height * (showsError ? 0.31 : 0.42), size.height - stackedChromeHeight)
            return max(96, min(min(size.width, stackedContentWidth) * 0.78, coverHeight / coverRatio))
        case .sideBySide:
            return min(size.width * sideBySideCoverFraction, (size.height * 0.56) / coverRatio)
        case .nightstand(let halves):
            let fraction = nightstandFaceIsWide(width: size.width) ? nightstandWideCoverFraction : nightstandNarrowCoverFraction
            let coverHeight = halves.upperHeight - nightstandCoverAllowance(width: size.width)
            return max(96, min(size.width * fraction, coverHeight / coverRatio))
        }
    }
}
