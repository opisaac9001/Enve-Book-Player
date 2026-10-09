import Foundation
import Logging

@MainActor
final class ProgressAutoSaver {
    static let shared = ProgressAutoSaver()

    var interval: TimeInterval = 30

    var onTick: (() async -> Void)?

    private var timer: Timer?

    var isActive: Bool { timer != nil }

    private var ticks: [UUID: Task<Void, Never>] = [:]
    private var isRetired = false

    init() {}

    func retire() async {
        isRetired = true
        stop()
        onTick = nil
        let pending = Array(ticks.values)
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
    }

    private func scheduleTick() {
        guard !isRetired else { return }
        let id = UUID()
        ticks[id] = Task {
            await onTick?()
            ticks[id] = nil
        }
    }

    func start() {
        guard !isRetired else { return }
        stop()
        AppLogger.sync.info("Starting auto-save timer (every \(Int(interval))s)")
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleTick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
