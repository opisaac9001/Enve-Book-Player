import Foundation

#if canImport(UIKit)
import UIKit
#endif

nonisolated enum DownloadStall: Sendable, Equatable {
    // Consecutive runs stopped at the same byte.
    case repeatedRuns
    // The server was silent while the app was foreground and online.
    case serverSilent
}

// Host activity keeps queued peers from being mistaken for stalled transfers.
nonisolated struct DownloadStallTracker: Sendable {
    static let hostSilenceLimit: Duration = .seconds(120)
    static let fruitlessRunLimit = 3

    private struct Transfer: Sendable {
        let host: String
        var hasRun = false
        var highWater: Int64 = 0
        var runPeak: Int64 = 0
        var lastTotal: Int64 = 0
        var fruitlessRuns = 0
        var runExcused: Bool
    }

    private var isForeground = true
    private var isOnline = true
    private var transfers: [String: Transfer] = [:]
    private var lastActivityByHost: [String: ContinuousClock.Instant] = [:]

    var isEmpty: Bool { transfers.isEmpty }
    private var isWatching: Bool { isForeground && isOnline }

    /// A new transfer gives its host a fresh silence window; re-registering a tracked key keeps its history.
    mutating func register(_ key: String, host: String, at now: ContinuousClock.Instant) {
        guard transfers[key] == nil else { return }
        transfers[key] = Transfer(host: host, runExcused: !isOnline)
        lastActivityByHost[host] = now
    }

    mutating func remove(_ key: String) {
        guard let host = transfers.removeValue(forKey: key)?.host,
            !transfers.values.contains(where: { $0.host == host })
        else { return }
        lastActivityByHost[host] = nil
    }

    // An initial chunk also detects restarts that stop at the same total every time.
    mutating func recordBytes(_ key: String, written: Int64, total: Int64, at now: ContinuousClock.Instant) -> DownloadStall? {
        guard var transfer = transfers[key] else { return nil }
        lastActivityByHost[transfer.host] = now
        let restarted = total < transfer.lastTotal || (written == total && transfer.runPeak > 0)
        if transfer.hasRun, restarted, endRun(&transfer, nextOffset: max(0, total - written)) {
            remove(key)
            return .repeatedRuns
        }
        transfer.hasRun = true
        transfer.lastTotal = total
        transfer.runPeak = max(transfer.runPeak, total)
        transfers[key] = transfer
        return nil
    }

    /// The first resume of a task created from resume data only sets its starting point.
    mutating func recordResume(_ key: String, offset: Int64) -> DownloadStall? {
        guard var transfer = transfers[key] else { return nil }
        if !transfer.hasRun {
            transfer.hasRun = true
            transfer.highWater = offset
            transfer.runPeak = offset
            transfer.lastTotal = offset
        } else if endRun(&transfer, nextOffset: offset) {
            remove(key)
            return .repeatedRuns
        }
        transfers[key] = transfer
        return nil
    }

    mutating func setForeground(_ isForeground: Bool, at now: ContinuousClock.Instant) {
        let wasWatching = isWatching
        self.isForeground = isForeground
        restartSilenceIfResumed(wasWatching, at: now)
    }

    /// A run that overlapped an offline period is not held against its transfer.
    mutating func setOnline(_ isOnline: Bool, at now: ContinuousClock.Instant) {
        let wasWatching = isWatching
        self.isOnline = isOnline
        if !isOnline { for key in transfers.keys { transfers[key]?.runExcused = true } }
        restartSilenceIfResumed(wasWatching, at: now)
    }

    mutating func silentTransfers(at now: ContinuousClock.Instant) -> [String] {
        guard isWatching else { return [] }
        let silentHosts = Set(lastActivityByHost.compactMap { host, last in
            last.duration(to: now) >= Self.hostSilenceLimit ? host : nil
        })
        guard !silentHosts.isEmpty else { return [] }
        let keys = transfers.compactMap { silentHosts.contains($0.value.host) ? $0.key : nil }
        for key in keys { remove(key) }
        return keys
    }

    private func endRun(_ transfer: inout Transfer, nextOffset: Int64) -> Bool {
        if transfer.runPeak > transfer.highWater {
            transfer.highWater = transfer.runPeak
            transfer.fruitlessRuns = 0
        } else if transfer.runPeak == transfer.highWater, !transfer.runExcused {
            transfer.fruitlessRuns += 1
        } else {
            transfer.fruitlessRuns = 0
        }
        transfer.runPeak = nextOffset
        transfer.lastTotal = nextOffset
        transfer.runExcused = !isOnline
        return transfer.fruitlessRuns >= Self.fruitlessRunLimit
    }

    // Time spent suspended or offline never counts as server silence.
    private mutating func restartSilenceIfResumed(_ wasWatching: Bool, at now: ContinuousClock.Instant) {
        guard !wasWatching, isWatching else { return }
        for host in lastActivityByHost.keys { lastActivityByHost[host] = now }
    }
}

// Shared across a profile's download paths; handlers run outside the lock.
nonisolated final class DownloadStallMonitor: @unchecked Sendable {
    typealias StallHandler = @Sendable (DownloadStall) -> Void

    static let checkInterval: Duration = .seconds(10)

    private let lock = NSLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private var tracker = DownloadStallTracker()
    private var handlers: [String: StallHandler] = [:]
    private var watchdog: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    private var isRetired = false

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    deinit {
        watchdog?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    #if canImport(UIKit)
    @MainActor
    func observeApplicationState() {
        setForeground(UIApplication.shared.applicationState != .background)
        let center = NotificationCenter.default
        let tokens = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.setForeground(false)
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.setForeground(true)
            },
        ]
        lock.withLock { observers += tokens }
    }
    #endif

    func track(_ task: URLSessionTask, onStall: @escaping StallHandler) {
        guard let key = task.taskDescription else { return }
        let host = (task.originalRequest ?? task.currentRequest)?.url?.host?.lowercased() ?? ""
        lock.withLock {
            guard !isRetired else { return }
            tracker.register(key, host: host, at: now())
            handlers[key] = onStall
            guard watchdog == nil else { return }
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.checkInterval)
                    guard let self, self.evaluate() else { return }
                }
            }
        }
    }

    func recordProgress(of task: URLSessionTask, bytesWritten: Int64, totalBytesWritten: Int64) {
        guard let key = task.taskDescription else { return }
        let stall = lock.withLock { tracker.recordBytes(key, written: bytesWritten, total: totalBytesWritten, at: now()) }
        report(stall, for: key)
    }

    func recordResume(of task: URLSessionTask, offset: Int64) {
        guard let key = task.taskDescription else { return }
        report(lock.withLock { tracker.recordResume(key, offset: offset) }, for: key)
    }

    func stopTracking(_ task: URLSessionTask) {
        guard let key = task.taskDescription else { return }
        lock.withLock {
            tracker.remove(key)
            handlers[key] = nil
        }
    }

    func setForeground(_ isForeground: Bool) {
        lock.withLock { tracker.setForeground(isForeground, at: now()) }
    }

    func setOnline(_ isOnline: Bool) {
        lock.withLock { tracker.setOnline(isOnline, at: now()) }
    }

    /// Fails transfers on silent hosts; returns whether anything is still tracked.
    @discardableResult
    func evaluate() -> Bool {
        let (stalled, isTracking) = lock.withLock { () -> ([StallHandler], Bool) in
            let stalled = tracker.silentTransfers(at: now()).compactMap { handlers.removeValue(forKey: $0) }
            let isTracking = !isRetired && !tracker.isEmpty
            if !isTracking { watchdog = nil }
            return (stalled, isTracking)
        }
        stalled.forEach { $0(.serverSilent) }
        return isTracking
    }

    func retire() {
        let (task, tokens) = lock.withLock { () -> (Task<Void, Never>?, [any NSObjectProtocol]) in
            let retired = (watchdog, observers)
            isRetired = true
            handlers = [:]
            watchdog = nil
            observers = []
            return retired
        }
        task?.cancel()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    private func report(_ stall: DownloadStall?, for key: String) {
        guard let stall, let handler = lock.withLock({ handlers.removeValue(forKey: key) }) else { return }
        handler(stall)
    }
}
