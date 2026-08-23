import Foundation

struct SleepTimerState: Codable, Equatable {
    var isActive: Bool
    var isPaused: Bool
    var endDate: Date?
    var remainingSeconds: TimeInterval
    var lastDurationMinutes: Int
    var lastEndedByExpiry: Bool

    var timerStartedDate: Date?
    var timerFiredDate: Date?
    var timerFiredPosition: TimeInterval?
    var timerFiredBookId: String?
}
