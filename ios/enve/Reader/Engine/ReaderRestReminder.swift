import Foundation
import Observation
import UIKit

struct ReaderRestClock {
    static let restingGap: TimeInterval = 5 * 60

    private var accumulated: TimeInterval = 0
    private var resumedAt: Date?
    private var pausedAt: Date?

    var isRunning: Bool { resumedAt != nil }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (resumedAt.map { now.timeIntervalSince($0) } ?? 0)
    }

    @discardableResult
    mutating func resume(at now: Date) -> Bool {
        guard resumedAt == nil else { return false }
        let rested = pausedAt.map { now.timeIntervalSince($0) >= Self.restingGap } ?? false
        if rested { accumulated = 0 }
        pausedAt = nil
        resumedAt = now
        return rested
    }

    mutating func pause(at now: Date) {
        guard resumedAt != nil else { return }
        accumulated = elapsed(at: now)
        resumedAt = nil
        pausedAt = now
    }

    mutating func restart(at now: Date) {
        accumulated = 0
        pausedAt = nil
        resumedAt = now
    }
}

@MainActor
@Observable
final class ReaderRestReminder {
    static let minuteRange = 5...240
    static let promptDuration: Duration = .seconds(60)

    private(set) var isDue = false
    private(set) var minutes = 0

    @ObservationIgnored private var clock = ReaderRestClock()
    @ObservationIgnored private var dueTask: Task<Void, Never>?
    @ObservationIgnored private var holdsPrompt = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start(minutes: Int) {
        stop()
        self.minutes = minutes
        clock.restart(at: .now)
        observe(UIApplication.didEnterBackgroundNotification) { $0.clock.pause(at: .now) }
        observe(UIApplication.willEnterForegroundNotification) { reminder in
            if reminder.clock.resume(at: .now) { reminder.isDue = false }
        }
        schedule()
    }

    func update(minutes: Int) {
        self.minutes = minutes
        if minutes == 0 { isDue = false }
        schedule()
    }

    func keepPromptVisible() {
        holdsPrompt = true
        dueTask?.cancel()
    }

    func dismiss() {
        isDue = false
        holdsPrompt = false
        clock.restart(at: .now)
        schedule()
    }

    func stop() {
        dueTask?.cancel()
        dueTask = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        clock = ReaderRestClock()
        isDue = false
        holdsPrompt = false
    }

    private func observe(_ name: Notification.Name, _ apply: @escaping @MainActor @Sendable (ReaderRestReminder) -> Void) {
        observers.append(
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self)
                    self.schedule()
                }
            }
        )
    }

    private var interval: TimeInterval {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-readerRestReminderSeconds"),
            let seconds = arguments.dropFirst(index + 1).first.flatMap(TimeInterval.init)
        {
            return seconds
        }
        #endif
        return TimeInterval(minutes * 60)
    }

    private func schedule() {
        dueTask?.cancel()
        guard minutes > 0 else { return }
        if isDue {
            guard !holdsPrompt else { return }
            dueTask = Task { [weak self] in
                try? await Task.sleep(for: Self.promptDuration)
                guard !Task.isCancelled else { return }
                self?.dismiss()
            }
            return
        }
        guard clock.isRunning else { return }
        let remaining = max(0, interval - clock.elapsed(at: .now))
        dueTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            self.clock.pause(at: .now)
            self.isDue = true
            self.schedule()
        }
    }
}
