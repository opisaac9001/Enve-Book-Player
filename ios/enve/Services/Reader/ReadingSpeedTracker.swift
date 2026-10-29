import Foundation

actor ReadingSpeedTracker {
    private struct Sample {
        let progressDelta: Double
        let seconds: TimeInterval
    }

    private var samples: [Sample] = []
    private var lastProgress: Double?
    private var lastTimestamp: TimeInterval?

    func recordPageTurn(progress: Double, totalPositions: Int = 0, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard progress.isFinite, (0...1).contains(progress), uptime.isFinite, uptime >= 0 else {
            pause()
            return
        }
        let previousProgress = lastProgress
        let previousTimestamp = lastTimestamp
        lastProgress = progress
        lastTimestamp = uptime
        guard let previousProgress, let previousTimestamp else { return }
        let delta = progress - previousProgress
        let elapsed = uptime - previousTimestamp
        let maximumAdvance = totalPositions > 0 ? 3.0 / Double(totalPositions) : 0.015
        guard delta > 0, delta <= maximumAdvance, (8...600).contains(elapsed) else { return }
        var seconds = elapsed
        if samples.count >= 3 {
            let rates = samples.map { $0.seconds / $0.progressDelta }.sorted()
            let median = rates[rates.count / 2]
            seconds = min(max(elapsed / delta, median / 2), median * 2) * delta
        }
        samples.append(Sample(progressDelta: delta, seconds: seconds))
        if samples.count > 20 { samples.removeFirst(samples.count - 20) }
    }

    var progressPerMinute: Double? {
        guard samples.count >= 3 else { return nil }
        let total = totals
        guard total.seconds >= 30, total.progress > 0 else { return nil }
        return total.progress / total.seconds * 60
    }

    func timeRemaining(from current: Double, to end: Double = 1.0) -> TimeInterval? {
        guard current.isFinite, end.isFinite, (0...1).contains(current), (0...1).contains(end),
            end > current, let rate = progressPerMinute else { return nil }
        return min((end - current) / rate * 60, 99 * 60 * 60)
    }

    var totals: (progress: Double, seconds: TimeInterval) {
        (samples.reduce(0) { $0 + $1.progressDelta }, samples.reduce(0) { $0 + $1.seconds })
    }

    func pause() {
        lastProgress = nil
        lastTimestamp = nil
    }

    func reset() {
        samples.removeAll()
        pause()
    }
}
