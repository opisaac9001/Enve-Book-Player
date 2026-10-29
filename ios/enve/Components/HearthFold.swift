import SwiftUI

// Hinge geometry uses view coordinates and includes inactive reserved regions.
nonisolated struct FoldLine: Equatable, Sendable {
    enum Axis: Equatable, Sendable {
        case vertical
        case horizontal
    }

    var axis: Axis
    // X for a vertical fold, Y for a horizontal fold.
    var center: CGFloat
    var clearance: CGFloat
    var isActive: Bool

    var inset: CGFloat { isActive ? clearance : 0 }

    nonisolated struct Halves: Equatable, Sendable {
        var upperHeight: CGFloat
        var foldCenter: CGFloat
        var lowerTop: CGFloat
        var lowerHeight: CGFloat
    }

    func halves(canvasHeight: CGFloat) -> Halves? {
        guard axis == .horizontal, canvasHeight > 0 else { return nil }
        let upperHeight = min(max(center - inset, 0), canvasHeight)
        let lowerTop = min(max(center + inset, 0), canvasHeight)
        return Halves(
            upperHeight: upperHeight,
            foldCenter: center,
            lowerTop: lowerTop,
            lowerHeight: canvasHeight - lowerTop
        )
    }
}

nonisolated extension FoldLine {
    init(regionFrame frame: CGRect, margins: EdgeInsets, isActive: Bool) {
        if frame.height >= frame.width {
            self.init(
                axis: .vertical,
                center: frame.midX,
                clearance: frame.width / 2 + max(margins.leading, margins.trailing),
                isActive: isActive
            )
        } else {
            self.init(
                axis: .horizontal,
                center: frame.midY,
                clearance: frame.height / 2 + max(margins.top, margins.bottom),
                isActive: isActive
            )
        }
    }
}

// The trailing safe-area inset contains the system bars on folding displays.
nonisolated struct SideColumn: Equatable, Sendable {
    static let minimumWidth: CGFloat = 60
    private static let topBreathingRoom: CGFloat = 24

    var width: CGFloat
    var statusBarBottom: CGFloat
    var topInset: CGFloat = 0

    var topClearance: CGFloat { max(0, Self.topBreathingRoom - topInset) }
}

nonisolated extension SideColumn {
    init?(trailingInset: CGFloat, topInset: CGFloat = 0, viewWidth: CGFloat, occlusions: [CGRect]) {
        guard trailingInset >= Self.minimumWidth else { return nil }
        self.init(
            width: trailingInset,
            statusBarBottom: occlusions.filter { $0.minX >= viewWidth - 1 }.map(\.maxY).max() ?? 0,
            topInset: topInset
        )
    }
}

extension GeometryProxy {
    nonisolated func hearthFold() -> FoldLine? {
        #if compiler(>=6.4)
        guard #available(iOS 27.1, *) else { return nil }
        guard let region = reservedRegions(kind: .division, options: .includeInactive).first else { return nil }
        return FoldLine(regionFrame: region.frame, margins: region.margins, isActive: region.isActive)
        #else
        return nil
        #endif
    }

    nonisolated func hearthSideColumn() -> SideColumn? {
        #if compiler(>=6.4)
        guard #available(iOS 27.1, *) else { return nil }
        return SideColumn(
            trailingInset: safeAreaInsets.trailing,
            topInset: safeAreaInsets.top,
            viewWidth: size.width,
            occlusions: reservedRegions(kind: .occlusion).map(\.frame)
        )
        #else
        return nil
        #endif
    }
}
