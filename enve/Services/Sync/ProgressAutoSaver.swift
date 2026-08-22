import Foundation
import Logging

@MainActor
final class ProgressAutoSaver {
    static let shared = ProgressAutoSaver()

    var interval: TimeInterval = 30

    var onTick: (() async -> Void)?

    private var timer: Timer?

    var isActive: Bool { timer != nil }

    private init() {}

    func start() {
        stop()
        AppLogger.sync.info("Starting auto-save timer (every \(Int(interval))s)")
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.onTick?()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
