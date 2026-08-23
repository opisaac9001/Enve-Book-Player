import Foundation

actor ReadingSpeedTracker {
    private struct Sample {
        let progressDelta: Double
        let seconds: TimeInterval
    }

    private var samples: [Sample] = []
    private var lastProgress: Double?
    private var lastTimestamp: Date?
    private let windowSize = 20

    func recordPageTurn(progress: Double, at date: Date = Date()) {
        defer {
            lastProgress = progress
            lastTimestamp = date
        }

        guard let prev = lastProgress, let prevTime = lastTimestamp else { return }

        let delta = progress - prev
        let elapsed = date.timeIntervalSince(prevTime)

        guard delta > 0, elapsed > 1, elapsed < 600 else { return }

        samples.append(Sample(progressDelta: delta, seconds: elapsed))
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }
    }

    var progressPerMinute: Double? {
        guard samples.count >= 3 else { return nil }
        let totalDelta = samples.reduce(0.0) { $0 + $1.progressDelta }
        let totalSeconds = samples.reduce(0.0) { $0 + $1.seconds }
        guard totalSeconds > 0 else { return nil }
        return (totalDelta / totalSeconds) * 60
    }

    func timeRemaining(from current: Double, to end: Double = 1.0) -> TimeInterval? {
        guard let ppm = progressPerMinute, ppm > 0 else { return nil }
        let remaining = end - current
        guard remaining > 0 else { return nil }
        return (remaining / ppm) * 60
    }

    var totals: (progress: Double, seconds: TimeInterval) {
        let p = samples.reduce(0.0) { $0 + $1.progressDelta }
        let s = samples.reduce(0.0) { $0 + $1.seconds }
        return (p, s)
    }

    func reset() {
        samples.removeAll()
        lastProgress = nil
        lastTimestamp = nil
    }
}
