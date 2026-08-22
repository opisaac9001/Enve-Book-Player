import Combine
import Foundation
import Logging

enum AutoSleepPolicy {

    nonisolated static func isInWindow(minutesOfDay: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        if start < end {
            return minutesOfDay >= start && minutesOfDay < end
        }
        return minutesOfDay >= start || minutesOfDay < end
    }

    nonisolated static func currentWindowStart(now: Date, startMinutes: Int, calendar: Calendar) -> Date {
        let todayStart = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(startMinutes * 60))
        if now >= todayStart { return todayStart }
        return calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
    }
}

@MainActor
final class AutoSleepService {
    static let shared = AutoSleepService()

    private let playback: any PlaybackControlling
    private var cancellables = Set<AnyCancellable>()
    private var armedWindowStart: Date?
    private var hasStarted = false

    private init(playback: any PlaybackControlling = ActivePlayback.controller) {
        self.playback = playback
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        playback.snapshots
            .map(\.isPlaying)
            .removeDuplicates()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
    }

    private func evaluate() {
        let preferences = LibraryDisplayPreferencesStore.shared.loadPreferences()
        guard preferences.autoSleepEnabled, playback.snapshot.isPlaying else { return }

        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let minutesOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        guard
            AutoSleepPolicy.isInWindow(
                minutesOfDay: minutesOfDay,
                start: preferences.autoSleepStartMinutes,
                end: preferences.autoSleepEndMinutes
            )
        else {
            armedWindowStart = nil
            return
        }

        let windowStart = AutoSleepPolicy.currentWindowStart(
            now: now,
            startMinutes: preferences.autoSleepStartMinutes,
            calendar: calendar
        )
        guard armedWindowStart != windowStart else { return }
        armedWindowStart = windowStart

        let player = PlayerViewModel.shared
        guard player.sleepTimer == nil else { return }
        player.startSleepTimer(minutes: preferences.autoSleepTimerMinutes)
        AppLogger.player.info("Auto-sleep armed for \(preferences.autoSleepTimerMinutes) min")
    }
}
