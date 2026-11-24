import Foundation
import Testing

@testable import enve

@MainActor
@Suite(.serialized)
struct PlayerSleepTimerPreferenceTests {
    @Test(arguments: [false, true])
    func chapterTimersRespectDisabledFadeAndLiveChanges(nextChapter: Bool) async throws {
        try await withPlayer { session, player in
            let manager = session.playback.manager
            let first = Chapter(id: "first", start: 0, end: 20, title: "First")
            let second = Chapter(id: "second", start: 20, end: 40, title: "Second")
            player.currentChapter = first
            player.chapters = [first, second]
            setFade(session, enabled: false, duration: 60)
            try await waitUntil { !player.preferences.sleepTimerFadeOutEnabled }
            if nextChapter { player.setSleepTimerToEndOfNextChapter() }
            else { player.setSleepTimerToEndOfChapter() }
            try await Task.sleep(for: .milliseconds(600))
            #expect(!player.isFadingOut)
            #expect(abs(session.playback.controller.snapshot.volume - 0.7) < 0.001)

            setFade(session, enabled: true, duration: 60)
            try await waitUntil { player.isFadingOut }
            #expect(session.playback.controller.snapshot.volume < 0.7)
            setFade(session, enabled: true, duration: 5)
            try await waitUntil { !player.isFadingOut }
            #expect(abs(session.playback.controller.snapshot.volume - 0.7) < 0.001)

            manager.currentTime = nextChapter ? 38 : 18
            try await waitUntil { player.isFadingOut }
            let expectedScale = 0.03 + 0.97 * pow(2.0 / 5.0, 1.8)
            #expect(abs(session.playback.controller.snapshot.volume - 0.7 * expectedScale) < 0.001)
            setFade(session, enabled: false, duration: 5)
            try await waitUntil { !player.isFadingOut }
            #expect(abs(session.playback.controller.snapshot.volume - 0.7) < 0.001)

            manager.currentTime = nextChapter ? 40 : 20
            try await waitUntil { player.sleepTimer == nil }
            #expect(!player.isPlaying)
            #expect(player.sleepTimerRemainingSeconds == 0)
        }
    }

    @Test func timedSleepReadsPersistedSettingsAndRestoresVolumeWhenDisabled() async throws {
        try await withPlayer { session, player in
            setFade(session, enabled: false, duration: 120)
            try await waitUntil { !player.preferences.sleepTimerFadeOutEnabled }
            player.startSleepTimer(minutes: 1)
            try await Task.sleep(for: .milliseconds(600))
            #expect(!player.isFadingOut)
            #expect(abs(session.playback.controller.snapshot.volume - 0.7) < 0.001)

            setFade(session, enabled: true, duration: 120)
            try await waitUntil { player.isFadingOut }
            #expect(session.playback.controller.snapshot.volume < 0.3)
            setFade(session, enabled: true, duration: 5)
            try await waitUntil { !player.isFadingOut }
            #expect(abs(session.playback.controller.snapshot.volume - 0.7) < 0.001)
            setFade(session, enabled: true, duration: 120)
            try await waitUntil { player.isFadingOut }
            setFade(session, enabled: false, duration: 120)
            try await waitUntil { !player.isFadingOut }
            #expect(abs(session.playback.controller.snapshot.volume - 0.7) < 0.001)
            #expect(player.sleepTimer != nil)
        }
    }

    @Test func snoozeUsesTheSameFadePreferenceAndCancellationRestoresVolume() async throws {
        try await withPlayer { session, player in
            setFade(session, enabled: true, duration: 600)
            try await waitUntil { player.preferences.sleepTimerFadeOutDuration == 600 }
            player.startSleepTimer(minutes: 1)
            try await waitUntil { player.isFadingOut }
            setFade(session, enabled: false, duration: 600)
            try await waitUntil { !player.preferences.sleepTimerFadeOutEnabled }
            player.snoozeSleepTimer()
            try await Task.sleep(for: .milliseconds(600))
            #expect(!player.isFadingOut)
            #expect(player.sleepTimerRemainingSeconds > 290)
            #expect(abs(session.playback.controller.snapshot.volume - 0.7) < 0.001)
            setFade(session, enabled: true, duration: 600)
            try await waitUntil { player.isFadingOut }
            #expect(session.playback.controller.snapshot.volume < 0.3)
            player.stopSleepTimer()
            try await waitUntil { player.sleepTimer == nil && !player.isFadingOut }
            #expect(abs(session.playback.controller.snapshot.volume - 0.7) < 0.001)
        }
    }

    private func setFade(_ session: ProfileSession, enabled: Bool, duration: TimeInterval) {
        var preferences = session.preferences.loadPreferences()
        preferences.sleepTimerFadeOutEnabled = enabled
        preferences.sleepTimerFadeOutDuration = duration
        session.preferences.savePreferences(preferences)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    private func withPlayer(_ action: (ProfileSession, PlayerViewModel) async throws -> Void) async throws {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let domain = "PlayerSleepTimerPreferenceTests.\(id)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let session = try ProfileSession(
            profile: FamilyProfile(id: id, name: "Sleep timer", role: .adult),
            storage: ProfileStorageLocations(
                profileID: id,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: root.appendingPathComponent("Caches")
            ),
            defaults: UserDefaults(suiteName: domain)!
        )
        do {
            let audio = root.appendingPathComponent("sleep-timer.wav")
            try PlaybackTestAudioFixture.wave(seconds: 120).write(to: audio)
            let book = Book(id: "sleep-fixture", title: "Sleep timer", duration: 120, source: .local, filePath: audio.path)
            let manager = session.playback.manager
            manager.playLocalBook(book, startPosition: 0)
            try await waitUntil { manager.isPlaying && !manager.isLoading }
            manager.pause()
            session.playback.controller.setVolume(0.7)
            let player = session.playback.player
            try await action(session, player)
            await session.retire()
        } catch {
            await session.retire()
            throw error
        }
    }
}
