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
        let todayStart = calendar.date(bySettingHour: startMinutes / 60, minute: startMinutes % 60, second: 0, of: now)!
        if now >= todayStart { return todayStart }
        return calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
    }
}

@MainActor
final class AutoSleepService {
    static let shared = AutoSleepService(playback: ActivePlayback.controller,
        preferences: .shared, player: { PlayerViewModel.shared })

    private let playback: any PlaybackControlling
    private let preferences: LibraryDisplayPreferencesStore
    private let player: @MainActor () -> PlayerViewModel
    private var isRetired = false
    private var cancellables = Set<AnyCancellable>()
    private var armedWindowStart: Date?
    private var hasStarted = false

    init(playback: any PlaybackControlling, preferences: LibraryDisplayPreferencesStore,
        player: @escaping @MainActor () -> PlayerViewModel) {
        self.playback = playback
        self.preferences = preferences
        self.player = player
    }

    func retire() {
        isRetired = true
        cancellables.removeAll()
        armedWindowStart = nil
    }

    func start() {
        guard !isRetired, !hasStarted else { return }
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
        guard !isRetired else { return }
        let preferences = preferences.loadPreferences()
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

        let player = player()
        guard player.sleepTimer == nil else { return }
        player.startSleepTimer(minutes: preferences.autoSleepTimerMinutes)
        AppLogger.player.info("Auto-sleep armed for \(preferences.autoSleepTimerMinutes) min")
    }
}
