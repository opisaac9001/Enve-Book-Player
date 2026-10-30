import CoreGraphics

enum ReaderSpreadPolicy {
    static let minimumSpreadWidth: CGFloat = 800
    static let minimumSpreadHeight: CGFloat = 500

    static func showsSpine(
        canvas: CGSize,
        columnMode: ReaderColumnOption,
        scrollEnabled: Bool,
        isFixedLayout: Bool,
        usesAccessibilityType: Bool = false
    ) -> Bool {
        guard !scrollEnabled, !isFixedLayout, !usesAccessibilityType, columnMode != .one else { return false }
        return canvas.width > canvas.height
            && canvas.width >= minimumSpreadWidth
            && canvas.height >= minimumSpreadHeight
    }

    static func lecternHalves(canvas: CGSize, pose: HingePose, fold: FoldLine?) -> FoldLine.Halves? {
        guard pose == .tabletop else { return nil }
        return fold?.halves(canvasHeight: canvas.height)
    }
}
