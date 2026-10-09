import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileServerSyncPreferencesTests {
    @Test func optInPersistsWithoutUploadingEarlierActivity() throws {
        let domain = "com.enve.tests.profile.sync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = ProfileServerSyncPreferences(defaults: defaults, isOwner: false)
        #expect(!preferences.isEnabled)
        let earlier = Date().addingTimeInterval(-60)
        preferences.isEnabled = true
        let cutoff = try #require(preferences.enabledSince)
        #expect(!preferences.allowsHistoryUpload(startedAt: earlier))
        #expect(preferences.allowsHistoryUpload(startedAt: cutoff))
        preferences.isEnabled = true
        #expect(preferences.enabledSince == cutoff)
        let reopened = ProfileServerSyncPreferences(defaults: defaults, isOwner: false)
        #expect(reopened.isEnabled)
        reopened.isEnabled = false
        #expect(!preferences.allowsHistoryUpload(startedAt: Date()))
    }

    @Test func existingOwnerKeepsSyncAndHistory() throws {
        let domain = "com.enve.tests.owner.sync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = ProfileServerSyncPreferences(defaults: defaults, isOwner: true)
        #expect(preferences.isEnabled)
        #expect(preferences.enabledSince == nil)
        #expect(preferences.allowsHistoryUpload(startedAt: .distantPast))
    }
}
