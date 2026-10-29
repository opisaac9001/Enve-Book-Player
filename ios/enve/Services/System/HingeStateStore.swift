import CoreGraphics
import Foundation
import Logging
import Observation

// Canvas shape alone cannot establish a fold; UIKit must report a hinge.
enum HingePose: Equatable {
    case flat
    case tabletop
    case book

    static func resolve(status: HingeStateStore.Status, canvas: CGSize) -> HingePose {
        guard status == .partiallyOpen, canvas.width > 0, canvas.height > 0 else { return .flat }
        return canvas.height > canvas.width ? .tabletop : .book
    }
}

@Observable
@MainActor
final class HingeStateStore {
    enum Status: String, Equatable {
        case unavailable
        case unknown
        case closed
        case partiallyOpen
        case fullyOpen
    }

    static let shared = HingeStateStore()

    private(set) var status: Status = .unavailable
    // UIKit reports radians.
    private(set) var angle: Double?

    #if DEBUG
    // Simulators without hinge input use -imagineHinge and -imagineFold overrides.
    private let debugOverride: Status?
    private let debugFoldAxis: FoldLine.Axis?
    #endif

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-imagineHinge"), arguments.indices.contains(index + 1) {
            debugOverride = Status(rawValue: arguments[index + 1])
        } else {
            debugOverride = nil
        }
        if let index = arguments.firstIndex(of: "-imagineFold"), arguments.indices.contains(index + 1) {
            switch arguments[index + 1] {
            case "vertical": debugFoldAxis = .vertical
            case "horizontal": debugFoldAxis = .horizontal
            default: debugFoldAxis = nil
            }
        } else {
            debugFoldAxis = nil
        }
        if let debugOverride {
            status = debugOverride
        }
        #endif
    }

    #if DEBUG
    func debugFold(canvas: CGSize) -> FoldLine? {
        guard let debugFoldAxis, canvas.width > 0, canvas.height > 0 else { return nil }
        return FoldLine(
            axis: debugFoldAxis,
            center: debugFoldAxis == .vertical ? canvas.width / 2 : canvas.height / 2,
            clearance: 40.5,
            isActive: status == .partiallyOpen
        )
    }
    #endif

    func noteHinge(status: Status, angle: Double?) {
        #if DEBUG
        if debugOverride != nil { return }
        #endif
        if self.status != status {
            AppLogger.general.info("[Hinge] status \(self.status.rawValue) -> \(status.rawValue)")
            self.status = status
        }
        if self.angle != angle {
            self.angle = angle
        }
    }

    func noteHingeUnavailable() {
        #if DEBUG
        if debugOverride != nil { return }
        #endif
        guard status != .unavailable else { return }
        AppLogger.general.info("[Hinge] updates ended")
        status = .unavailable
        angle = nil
    }

    func pose(for canvas: CGSize) -> HingePose {
        HingePose.resolve(status: status, canvas: canvas)
    }

    var isKnown: Bool { status != .unavailable }

    // Shadow depth reaches 1 at a right angle.
    func spineDepth(flat: Double) -> Double {
        guard status == .partiallyOpen else { return flat }
        guard let angle else { return 1 }
        let folded = min(max((Double.pi - angle) / (Double.pi / 2), 0), 1)
        return flat + (1 - flat) * folded
    }
}
