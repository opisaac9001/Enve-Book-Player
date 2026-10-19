import Foundation
import Testing

@testable import enve

@Suite(.serialized) @MainActor
struct MediaOverlayPlayerSpeedTests {
    private static let speedKey = "readAloud.speed"

    @Test func nonFiniteSpeedRequestsKeepTheCurrentPreference() throws {
        let suiteName = "MediaOverlayPlayerSpeedTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = MediaOverlayPlayer(defaults: defaults)

        player.setSpeed(1.75)
        player.setSpeed(.nan)
        player.setSpeed(.infinity)
        player.setSpeed(-.infinity)

        #expect(player.playbackRate == 1.75)
        #expect(defaults.double(forKey: Self.speedKey) == 1.75)
    }

    @Test(arguments: [Double.nan, .infinity, 0, 0.25, 3.5])
    func invalidPersistedSpeedIsIgnoredWithoutOverwritingIt(stored: Double) throws {
        let suiteName = "MediaOverlayPlayerSpeedTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = MediaOverlayPlayer(defaults: defaults)
        player.setSpeed(1.75)
        defaults.set(stored, forKey: Self.speedKey)

        player.loadPersistedSpeed()

        #expect(player.playbackRate == 1.75)
        let persisted = defaults.double(forKey: Self.speedKey)
        #expect(persisted == stored || (persisted.isNaN && stored.isNaN))
    }

    @Test func validPersistedSpeedIsApplied() throws {
        let suiteName = "MediaOverlayPlayerSpeedTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(2.25, forKey: Self.speedKey)
        let player = MediaOverlayPlayer(defaults: defaults)

        player.loadPersistedSpeed()

        #expect(player.playbackRate == 2.25)
        #expect(defaults.double(forKey: Self.speedKey) == 2.25)
    }
}
