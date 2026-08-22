import Foundation
import Testing

@testable import enve

struct AutoSleepPolicyTests {
    @Test func sameDayWindow() {
        #expect(AutoSleepPolicy.isInWindow(minutesOfDay: 13 * 60, start: 12 * 60, end: 14 * 60))
        #expect(!AutoSleepPolicy.isInWindow(minutesOfDay: 15 * 60, start: 12 * 60, end: 14 * 60))
        #expect(!AutoSleepPolicy.isInWindow(minutesOfDay: 14 * 60, start: 12 * 60, end: 14 * 60))
    }

    @Test func overnightWindow() {
        let start = 22 * 60
        let end = 6 * 60
        #expect(AutoSleepPolicy.isInWindow(minutesOfDay: 23 * 60, start: start, end: end))
        #expect(AutoSleepPolicy.isInWindow(minutesOfDay: 2 * 60, start: start, end: end))
        #expect(!AutoSleepPolicy.isInWindow(minutesOfDay: 12 * 60, start: start, end: end))
        #expect(!AutoSleepPolicy.isInWindow(minutesOfDay: 6 * 60, start: start, end: end))
    }

    @Test func emptyWindowNeverMatches() {
        #expect(!AutoSleepPolicy.isInWindow(minutesOfDay: 600, start: 600, end: 600))
    }

    @Test func windowStartRollsBackAcrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let twoAM = calendar.date(from: DateComponents(year: 2026, month: 7, day: 25, hour: 2))!
        let start = AutoSleepPolicy.currentWindowStart(now: twoAM, startMinutes: 22 * 60, calendar: calendar)
        let expected = calendar.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: 22))!
        #expect(start == expected)

        let elevenPM = calendar.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: 23))!
        let sameNight = AutoSleepPolicy.currentWindowStart(now: elevenPM, startMinutes: 22 * 60, calendar: calendar)
        #expect(sameNight == expected)
    }
}
