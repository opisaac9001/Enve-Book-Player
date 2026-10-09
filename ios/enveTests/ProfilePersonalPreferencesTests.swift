import Foundation
import Testing

@testable import enve

@MainActor
struct ProfilePersonalPreferencesTests {
    @Test func profilePreferenceFactoryPreservesOwnerAndKeepsNewProfilesEmpty() throws {
        #expect(try ProfileStorageLocations.owner.openPreferences() === UserDefaults.standard)
        let first = ProfileStorageLocations(profileID: UUID().uuidString)
        let second = ProfileStorageLocations(profileID: UUID().uuidString)
        let firstDefaults = try first.openPreferences()
        let secondDefaults = try second.openPreferences()
        defer {
            firstDefaults.removePersistentDomain(forName: first.preferencesDomain!)
            secondDefaults.removePersistentDomain(forName: second.preferencesDomain!)
        }
        PlayerStateStore(defaults: firstDefaults).saveLastPlayedBookId("first-book")
        #expect(PlayerStateStore(defaults: secondDefaults).loadLastPlayedBookId() == nil)
        #expect(PlayerStateStore(defaults: try first.openPreferences()).loadLastPlayedBookId() == "first-book")
    }

    @Test func libraryAppearanceAndPlayerPreferencesStayInTheirProfile() throws {
        let firstName = "com.enve.tests.profile.preferences.\(UUID().uuidString)"
        let secondName = "com.enve.tests.profile.preferences.\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: firstName))
        let second = try #require(UserDefaults(suiteName: secondName))
        defer {
            first.removePersistentDomain(forName: firstName)
            second.removePersistentDomain(forName: secondName)
        }
        let firstLibrary = LibraryDisplayPreferencesStore(defaults: first)
        let secondLibrary = LibraryDisplayPreferencesStore(defaults: second)
        let firstPlayer = PlayerStateStore(defaults: first)
        let secondPlayer = PlayerStateStore(defaults: second)
        firstLibrary.saveBookCardStyle(.coverOnly)
        firstPlayer.saveLastPlayedBookId("owner-book")
        firstPlayer.saveWeeklyGoal(hours: 5)
        #expect(secondLibrary.loadBookCardStyle() == .standard)
        #expect(secondPlayer.loadLastPlayedBookId() == nil)
        secondLibrary.saveBookCardStyle(.compact)
        secondPlayer.saveLastPlayedBookId("child-book")
        secondPlayer.saveWeeklyGoal(hours: 1.5)

        #expect(firstLibrary.loadBookCardStyle() == .coverOnly)
        #expect(firstPlayer.loadLastPlayedBookId() == "owner-book")
        #expect(firstPlayer.loadWeeklyGoal() == 5)
        #expect(secondPlayer.loadWeeklyGoal() == 1.5)
        #expect(LibraryDisplayPreferencesStore(defaults: second).loadBookCardStyle() == .compact)
        #expect(PlayerStateStore(defaults: second).loadLastPlayedBookId() == "child-book")
    }
}
