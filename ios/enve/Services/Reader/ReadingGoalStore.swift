import Foundation

struct ReadingGoalProgress: Equatable, Sendable {
    let targetMinutes: Int
    let secondsRead: TimeInterval

    var completedMinutes: Int { Int(secondsRead / 60) }
    var remainingMinutes: Int { Int(ceil(max(0, Double(targetMinutes) * 60 - secondsRead) / 60)) }
    var fraction: Double { min(1, secondsRead / (Double(targetMinutes) * 60)) }
    var isComplete: Bool { secondsRead >= Double(targetMinutes) * 60 }
}

@MainActor
@Observable
final class ReadingGoalStore {
    static let minuteRange = 1...240
    static let suggestedMinutes = 20
    private static let minutesKey = "readingGoal.dailyMinutes"

    private let defaults: UserDefaults
    private(set) var dailyMinutes: Int?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.integer(forKey: Self.minutesKey)
        dailyMinutes = Self.minuteRange.contains(stored) ? stored : nil
    }

    func setDailyMinutes(_ minutes: Int?) {
        if let minutes {
            precondition(Self.minuteRange.contains(minutes))
            defaults.set(minutes, forKey: Self.minutesKey)
        } else {
            defaults.removeObject(forKey: Self.minutesKey)
        }
        dailyMinutes = minutes
    }

    func progress(dailySeconds: [String: TimeInterval], on date: Date = .now, calendar: Calendar = .current) -> ReadingGoalProgress? {
        guard let dailyMinutes else { return nil }
        let seconds = dailySeconds[Self.dayKey(for: date, calendar: calendar)] ?? 0
        return ReadingGoalProgress(targetMinutes: dailyMinutes, secondsRead: seconds.isFinite ? max(0, seconds) : 0)
    }

    nonisolated static func dayKey(for date: Date, calendar: Calendar) -> String {
        // ReadingStatsSnapshot stores Gregorian day labels in the reader's local time zone.
        var ledgerCalendar = Calendar(identifier: .gregorian)
        ledgerCalendar.timeZone = calendar.timeZone
        let day = ledgerCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!)
    }
}
