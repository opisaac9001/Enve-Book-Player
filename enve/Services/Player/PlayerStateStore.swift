import Foundation

@MainActor
final class PlayerStateStore {
    static let shared = PlayerStateStore()

    private static let sleepTimerStateKey = "sleepTimerState"
    private static let listeningWeeklyGoalKey = "listeningWeeklyGoalHours"
    private static let monthlyBookGoalKey = "listeningMonthlyBookGoal"
    private static let lastPlayedBookIdKey = "lastPlayedBookId"

    private static let defaultMonthlyBookGoal = 4

    private let userDefaults = UserDefaults.standard

    private init() {}

    func saveSleepTimer(_ state: SleepTimerState?) {
        guard let state else {
            userDefaults.removeObject(forKey: Self.sleepTimerStateKey)
            return
        }
        if let encoded = try? JSONEncoder().encode(state) {
            userDefaults.set(encoded, forKey: Self.sleepTimerStateKey)
        }
    }

    func loadSleepTimer() -> SleepTimerState? {
        guard let data = userDefaults.data(forKey: Self.sleepTimerStateKey) else { return nil }
        return try? JSONDecoder().decode(SleepTimerState.self, from: data)
    }

    func saveWeeklyGoal(hours: Double) {
        userDefaults.set(hours, forKey: Self.listeningWeeklyGoalKey)
    }

    func loadWeeklyGoal() -> Double {
        userDefaults.double(forKey: Self.listeningWeeklyGoalKey)
    }

    func saveMonthlyBookGoal(count: Int) {
        userDefaults.set(count, forKey: Self.monthlyBookGoalKey)
    }

    func loadMonthlyBookGoal() -> Int {
        let value = userDefaults.integer(forKey: Self.monthlyBookGoalKey)
        return value > 0 ? value : Self.defaultMonthlyBookGoal
    }

    func saveLastPlayedBookId(_ bookId: String?) {
        userDefaults.set(bookId, forKey: Self.lastPlayedBookIdKey)
    }

    func loadLastPlayedBookId() -> String? {
        userDefaults.string(forKey: Self.lastPlayedBookIdKey)
    }
}
