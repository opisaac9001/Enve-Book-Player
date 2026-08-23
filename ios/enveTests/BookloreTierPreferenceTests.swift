import Foundation
import Testing

@testable import enve

@MainActor
struct BookloreTierPreferenceTests {
    @Test func aFreshConnectionHasNoRememberedTier() {
        let suite = Suite()
        defer { suite.tearDown() }

        #expect(suite.preference.restored == nil)
    }

    @Test func aDemotionSurvivesUntilItIsCleared() {
        let suite = Suite()
        defer { suite.tearDown() }

        suite.preference.store(.legacy)
        #expect(suite.preference.restored == .legacy)

        suite.preference.clear()
        #expect(suite.preference.restored == nil)
    }

    @Test func komgaTierWrittenByAnOlderBuildStillRestores() {
        let suite = Suite()
        defer { suite.tearDown() }

        suite.defaults.set("komga", forKey: "BookloreTier-\(suite.connectionId.uuidString)")

        #expect(suite.preference.restored == .komga)
    }

    @Test func anUnrecognisedStoredValueIsIgnored() {
        let suite = Suite()
        defer { suite.tearDown() }

        suite.defaults.set("opds", forKey: "BookloreTier-\(suite.connectionId.uuidString)")

        #expect(suite.preference.restored == nil)
    }

    @Test func theUpgradeProbeIsRateLimitedToOncePerInterval() {
        let suite = Suite()
        defer { suite.tearDown() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(suite.preference.consumeUpgradeProbe(now: start))
        #expect(!suite.preference.consumeUpgradeProbe(now: start.addingTimeInterval(3_600)))
        #expect(suite.preference.consumeUpgradeProbe(now: start.addingTimeInterval(86_401)))
    }

    @Test func clearingAlsoResetsTheProbeBackoff() {
        let suite = Suite()
        defer { suite.tearDown() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(suite.preference.consumeUpgradeProbe(now: start))
        suite.preference.clear()

        #expect(suite.preference.consumeUpgradeProbe(now: start))
    }

    private struct Suite {
        let connectionId = UUID()
        let suiteName: String
        let defaults: UserDefaults
        let preference: BookloreTierPreference

        init() {
            suiteName = "BookloreTierPreferenceTests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            preference = BookloreTierPreference(connectionId: connectionId, defaults: defaults)
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
