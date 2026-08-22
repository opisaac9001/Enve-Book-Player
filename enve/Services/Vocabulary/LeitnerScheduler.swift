import Foundation

enum LeitnerScheduler {

    enum Action: Sendable {
        case again
        case gotIt
        case mastered
    }

    static let intervalDays: [Int: Int] = [
        1: 1,
        2: 3,
        3: 7,
        4: 14,
        5: 30,
    ]

    struct Result: Equatable, Sendable {
        var newBox: Int
        var nextReviewAt: Date?
        var reviewStreak: Int
    }

    static func apply(
        action: Action,
        currentBox: Int,
        currentStreak: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Result {
        switch action {
        case .again:

            return Result(
                newBox: 1,
                nextReviewAt: nextReviewDate(daysAhead: intervalDays[1] ?? 1, from: now, calendar: calendar),
                reviewStreak: 0
            )
        case .gotIt:
            let promoted = min(currentBox + 1, 4)

            if currentStreak >= 3 && currentBox >= 4 {
                return Result(newBox: 5, nextReviewAt: nil, reviewStreak: currentStreak + 1)
            }
            let interval = intervalDays[promoted] ?? 1
            return Result(
                newBox: promoted,
                nextReviewAt: nextReviewDate(daysAhead: interval, from: now, calendar: calendar),
                reviewStreak: currentStreak + 1
            )
        case .mastered:
            return Result(newBox: 5, nextReviewAt: nil, reviewStreak: currentStreak + 1)
        }
    }

    private static func nextReviewDate(daysAhead: Int, from now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: daysAhead, to: today) ?? now
    }
}
