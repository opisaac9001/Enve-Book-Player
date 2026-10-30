import Foundation

enum ReaderPinchResizeEvent: Equatable {
    case began
    case changed(scale: Double)
    case ended(scale: Double)
    case cancelled
}

enum ReaderPinchResize {
    static let minimumFontSize = 0.5
    static let maximumFontSize = 3.0
    static let step = 0.1

    static let deadZone = 0.08

    static let tapGuard: TimeInterval = 0.35

    static func snap(_ size: Double) -> Double {
        let bounded = min(max(size, minimumFontSize), maximumFontSize)
        let steps = ((bounded - minimumFontSize) / step).rounded()
        return ((minimumFontSize + steps * step) * 10).rounded() / 10
    }

    static func target(startSize: Double, scale: Double) -> Double? {
        guard scale.isFinite, scale > 0, abs(scale - 1) >= deadZone else { return nil }
        return snap(startSize * scale)
    }

    static func percentLabel(_ size: Double) -> String {
        "\(Int((size * 100).rounded()))%"
    }
}
