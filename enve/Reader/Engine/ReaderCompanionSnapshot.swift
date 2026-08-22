import Foundation
@preconcurrency import ReadiumNavigator

@MainActor
final class ReaderCompanionSnapshot {
    static let readAloudSpeeds: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0]

    var onChange: (() -> Void)?

    var isActive = false {
        willSet { notifyIfNeeded(isActive != newValue) }
    }
    var lastHighlightBroadcast: Date = .distantPast
    var screenCapture: CompanionScreenCapture?
    var videoStreamStarted = false
    var columnOverride: ReadiumNavigator.ColumnCount?

    func shouldBroadcastHighlight(now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(lastHighlightBroadcast) >= 0.4 else { return false }
        lastHighlightBroadcast = now
        return true
    }

    private func notifyIfNeeded(_ shouldNotify: Bool) {
        if shouldNotify {
            onChange?()
        }
    }
}
