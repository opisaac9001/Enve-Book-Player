import Foundation

actor ConcurrencyLimiter {
    private let maxConcurrent: Int
    private var inFlight = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append(continuation)
        }
        inFlight += 1
    }

    func release() {
        inFlight -= 1
        if let next = waiting.first {
            waiting.removeFirst()
            next.resume()
        }
    }
}

actor CoverCircuitBreaker {
    private let failureThreshold: Int
    private let windowSeconds: TimeInterval
    private let openSeconds: TimeInterval
    private var recentFailures: [Date] = []
    private var openedAt: Date?

    init(failureThreshold: Int = 5, windowSeconds: TimeInterval = 10, openSeconds: TimeInterval = 30) {
        self.failureThreshold = failureThreshold
        self.windowSeconds = windowSeconds
        self.openSeconds = openSeconds
    }

    func isOpen() -> Bool {
        guard let openedAt else { return false }
        if Date().timeIntervalSince(openedAt) > openSeconds {
            self.openedAt = nil
            recentFailures.removeAll()
            return false
        }
        return true
    }

    func recordFailure() {
        let now = Date()
        recentFailures.append(now)
        recentFailures.removeAll { now.timeIntervalSince($0) > windowSeconds }
        if recentFailures.count >= failureThreshold {
            openedAt = now
        }
    }

    func recordSuccess() {

        recentFailures.removeAll()
    }

    func reset() {
        recentFailures.removeAll()
        openedAt = nil
    }
}

actor CoverFailureCache {
    private var failureTimestamps: [String: Date] = [:]
    private let cooldownSeconds: TimeInterval

    init(cooldownSeconds: TimeInterval = 60) {
        self.cooldownSeconds = cooldownSeconds
    }

    func shouldSkip(_ url: URL) -> Bool {
        guard let recordedAt = failureTimestamps[url.absoluteString] else { return false }
        if Date().timeIntervalSince(recordedAt) > cooldownSeconds {
            failureTimestamps.removeValue(forKey: url.absoluteString)
            return false
        }
        return true
    }

    func recordFailure(_ url: URL) {
        failureTimestamps[url.absoluteString] = Date()
    }

    func clear() {
        failureTimestamps.removeAll()
    }
}
