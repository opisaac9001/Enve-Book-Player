import Combine
import Foundation
import Logging

public final class PlayerSleepTimerService: ObservableObject {
    @Published public private(set) var sleepTimer: Date?
    @Published public private(set) var remainingSeconds: TimeInterval = 0
    @Published public private(set) var isFadingOut = false
    private let fadeWindowSeconds: TimeInterval = 30
    private let tickIntervalSeconds: TimeInterval = 0.25

    private var timerTask: Task<Void, Never>?
    private var fadeOutTask: Task<Void, Never>?
    private let onTimerFinished: (Bool) -> Void
    private let onFadeProgress: (TimeInterval) -> Void
    private let onFadeReset: () -> Void

    public init(
        onTimerFinished: @escaping (Bool) -> Void,
        onFadeProgress: @escaping (TimeInterval) -> Void = { _ in },
        onFadeReset: @escaping () -> Void = {}
    ) {
        self.onTimerFinished = onTimerFinished
        self.onFadeProgress = onFadeProgress
        self.onFadeReset = onFadeReset
    }

    public func startTimer(minutes: Int, fadeOut: Bool) {
        stopTimer()

        let duration = TimeInterval(minutes) * 60
        let targetDate = Date().addingTimeInterval(duration)
        sleepTimer = targetDate
        remainingSeconds = duration

        timerTask = Task {
            while !Task.isCancelled {
                let now = Date()
                if now >= targetDate {
                    await MainActor.run {
                        if fadeOut {
                            self.onFadeReset()
                            self.isFadingOut = false
                        }
                        self.sleepTimer = nil
                        self.remainingSeconds = 0
                        self.onTimerFinished(false)
                    }
                    break
                }

                let remaining = targetDate.timeIntervalSince(now)

                await MainActor.run {
                    self.remainingSeconds = remaining

                    if fadeOut {
                        if remaining <= self.fadeWindowSeconds {
                            if !self.isFadingOut {
                                self.isFadingOut = true
                                AppLogger.player.info("[SleepTimer] Entering fade window (\(Int(self.fadeWindowSeconds))s)")
                            }
                            self.onFadeProgress(remaining)
                        } else if self.isFadingOut {
                            self.isFadingOut = false
                            self.onFadeReset()
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: UInt64(tickIntervalSeconds * 1_000_000_000))
            }
        }
    }

    public func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        fadeOutTask?.cancel()
        fadeOutTask = nil
        onFadeReset()
        sleepTimer = nil
        remainingSeconds = 0
        isFadingOut = false
    }

    public func snooze() {
        startTimer(minutes: AppConstants.SleepTimer.snoozeDurationMinutes, fadeOut: true)
    }
}
