import Foundation
import Testing

@testable import enve

@MainActor
struct ReadingGoalTests {
    @Test func goalsAreOptionalPersistedAndIsolatedByProfile() throws {
        let first = try fixture()
        let second = try fixture()
        defer { first.clean(); second.clean() }
        #expect(first.store.dailyMinutes == nil)
        first.store.setDailyMinutes(25)
        second.store.setDailyMinutes(45)
        #expect(ReadingGoalStore(defaults: first.defaults).dailyMinutes == 25)
        #expect(ReadingGoalStore(defaults: second.defaults).dailyMinutes == 45)
        first.store.setDailyMinutes(nil)
        #expect(ReadingGoalStore(defaults: first.defaults).dailyMinutes == nil)
        #expect(second.store.dailyMinutes == 45)
    }

    @Test func usesOnlyTodaysReadingLedger() throws {
        let f = try fixture()
        defer { f.clean() }
        f.store.setDailyMinutes(20)
        let progress = try #require(f.store.progress(dailySeconds: ["2026-11-13": 3600, "2026-11-14": 450],
            on: date("2026-11-14T20:00:00Z"), calendar: calendar()))
        #expect(progress.completedMinutes == 7)
        #expect(progress.remainingMinutes == 13)
        #expect(progress.fraction == 0.375)
        #expect(!progress.isComplete)
    }

    @Test func completionRequiresTheFullTargetAndCapsTheProgressBar() throws {
        let f = try fixture()
        defer { f.clean() }
        f.store.setDailyMinutes(10)
        for seconds in [599.9, 600, 900] {
            let progress = try #require(f.store.progress(dailySeconds: ["2026-11-14": seconds],
                on: date("2026-11-14T20:00:00Z"), calendar: calendar()))
            #expect(progress.isComplete == (seconds >= 600))
            #expect(progress.fraction <= 1)
            #expect(progress.remainingMinutes == (seconds < 600 ? 1 : 0))
        }
    }

    @Test func editingTargetReusesRecordedTimeWithoutChangingHistory() throws {
        let f = try fixture()
        defer { f.clean() }
        let daily = ["2026-11-14": 900.0]
        let now = date("2026-11-14T20:00:00Z")
        f.store.setDailyMinutes(20)
        #expect(f.store.progress(dailySeconds: daily, on: now, calendar: calendar())?.isComplete == false)
        f.store.setDailyMinutes(10)
        #expect(f.store.progress(dailySeconds: daily, on: now, calendar: calendar())?.isComplete == true)
        #expect(f.store.progress(dailySeconds: daily, on: now, calendar: calendar())?.secondsRead == 900)
        f.store.setDailyMinutes(nil)
        #expect(f.store.progress(dailySeconds: daily, on: now, calendar: calendar()) == nil)
    }

    @Test func emptyAndInvalidLedgerValuesDoNotCompleteAGoal() throws {
        let f = try fixture()
        defer { f.clean() }
        f.store.setDailyMinutes(20)
        let cases: [[String: Double]] = [[:], ["2026-11-14": -10], ["2026-11-14": .nan], ["2026-11-14": .infinity]]
        for daily in cases {
            let progress = try #require(f.store.progress(dailySeconds: daily, on: date("2026-11-14T20:00:00Z"), calendar: calendar()))
            #expect(progress.completedMinutes == 0)
            #expect(progress.remainingMinutes == 20)
            #expect(progress.fraction == 0)
        }
    }

    @Test func progressResetsAtLocalMidnight() throws {
        let f = try fixture()
        defer { f.clean() }
        f.store.setDailyMinutes(20)
        let daily = ["2026-11-14": 1200.0]
        #expect(f.store.progress(dailySeconds: daily, on: date("2026-11-15T07:59:59Z"), calendar: calendar())?.isComplete == true)
        #expect(f.store.progress(dailySeconds: daily, on: date("2026-11-15T08:00:00Z"), calendar: calendar())?.secondsRead == 0)
    }

    @Test func daylightSavingTransitionsKeepTheSameLocalDay() {
        let cal = calendar()
        for instant in ["2026-03-08T09:59:59Z", "2026-03-08T10:00:00Z"] {
            #expect(ReadingGoalStore.dayKey(for: date(instant), calendar: cal) == "2026-03-08")
        }
        for instant in ["2026-11-01T08:30:00Z", "2026-11-01T09:30:00Z"] {
            #expect(ReadingGoalStore.dayKey(for: date(instant), calendar: cal) == "2026-11-01")
        }
    }

    @Test func changingTimeZoneSelectsTheMatchingDayAndNonGregorianCalendarsUseLedgerKeys() {
        let instant = date("2026-11-15T01:00:00Z")
        var tokyo = Calendar(identifier: .buddhist)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(ReadingGoalStore.dayKey(for: instant, calendar: calendar()) == "2026-11-14")
        #expect(ReadingGoalStore.dayKey(for: instant, calendar: tokyo) == "2026-11-15")
    }

    private struct Fixture {
        let name: String
        let defaults: UserDefaults
        let store: ReadingGoalStore
        func clean() { defaults.removePersistentDomain(forName: name) }
    }

    private func fixture() throws -> Fixture {
        let name = "ReadingGoalTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return Fixture(name: name, defaults: defaults, store: ReadingGoalStore(defaults: defaults))
    }

    private func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
}
