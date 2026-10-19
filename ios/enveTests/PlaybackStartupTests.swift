import Foundation
import Testing

@testable import enve

@MainActor
private final class StartupGate {
    var entered = false
    var completed = false
    var closedSessionIDs: [String] = []
    func recordClose(_ id: String) { closedSessionIDs.append(id) }
    var entryCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        entryCount += 1
        await withCheckedContinuation { continuations.append($0) }
        completed = true
    }
    func release() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class StartupProviderStub: PlexProvider, @unchecked Sendable {
    let gate: StartupGate?
    let failsAfterRelease: Bool
    let audioURL: String
    var progressRequests = 0

    init(gate: StartupGate? = nil, failsAfterRelease: Bool = false, audioURL: String = "file:///nonexistent-fixture.wav") {
        self.gate = gate
        self.failsAfterRelease = failsAfterRelease
        self.audioURL = audioURL
        super.init(connection: ServerConnection(name: "Fixture", url: "https://fixture.invalid", type: .plex))
    }

    override func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        await gate?.wait()
        if failsAfterRelease { throw URLError(.networkConnectionLost) }
        return PlaybackSessionInfo(
            sessionId: "session-\(book.id)",
            audioTracks: gate == nil ? [] : [AudioTrackInfo(index: 0, startOffset: 0, duration: 90,
                contentUrl: audioURL, mimeType: "audio/wav")],
            chapters: []
        )
    }

    override func reportPlayback(_ event: ServerPlaybackEvent, book: Book, sessionId: String, position: TimeInterval) async {
        if case .stopped = event { gate?.recordClose(sessionId) }
    }

    override func fetchAudiobookProgress(for book: Book) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isFinished: Bool)? {
        progressRequests += 1
        return (40, 40.0 / 90, 0, Date(), false)
    }

}

@MainActor
@Suite(.serialized)
struct PlaybackStartupTests {
    @Test func downloadedBookAdoptsNewerServerProgressWhileOnline() async throws {
        let fixture = try StartupFixture(startupTimeout: 10)
        fixture.session.defaults.set(true, forKey: "profileServerSyncEnabled")
        try await waitUntil { NetworkPolicyService.shared.isConnected }
        let book = makeBook("downloaded")
        let directory = fixture.session.localStorage.bookAudioDirectory(for: book.downloadKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PlaybackTestAudioFixture.wave(seconds: 90).write(to: directory.appendingPathComponent("chapter_0.wav"))
        let provider = StartupProviderStub()
        fixture.manager.playBook(book, provider: provider)
        try await waitUntil { fixture.manager.isPlaying && !fixture.manager.isLoading }
        #expect(provider.progressRequests == 1)
        #expect(fixture.manager.currentTime >= 39)
        #expect(fixture.manager.playbackError == nil)
        await fixture.close()
    }

    @Test func deadlineReturnsBeforeUncooperativeOperationCompletes() async throws {
        let gate = StartupGate()
        do {
            _ = try await PlaybackStartupDeadline.run(seconds: 0.1) {
                await gate.wait()
                return 42
            }
            Issue.record("Expected timeout")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        #expect(!gate.completed)
        #expect(gate.entered)
        gate.release()
        await Task.yield()
    }

    @Test func callerCancellationReturnsWithoutWaitingForLateResult() async throws {
        let gate = StartupGate()
        let task = Task { @MainActor in
            try await PlaybackStartupDeadline.run(seconds: 30) {
                await gate.wait()
                return 42
            }
        }
        try await waitUntil { gate.entered }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        gate.release()
        await Task.yield()
    }

    @Test func successfulAndFailedOperationsKeepTheirResult() async throws {
        let result = try await PlaybackStartupDeadline.run(seconds: 1) { 42 }
        #expect(result == 42)
        do {
            _ = try await PlaybackStartupDeadline.run(seconds: 1) { () -> Int in
                throw URLError(.cannotConnectToHost)
            }
            Issue.record("Expected provider failure")
        } catch { #expect((error as? URLError)?.code == .cannotConnectToHost) }
    }

    @Test func managerBoundsStartupAndIgnoresLateSessionAfterTimeout() async throws {
        let fixture = try StartupFixture()
        let gate = StartupGate()
        let provider = StartupProviderStub(gate: gate)
        let manager = fixture.manager
        manager.playBook(makeBook("A"), provider: provider)
        try await waitUntil { !manager.isLoading && manager.playbackError != nil }
        #expect(manager.currentBook?.id == "A")
        #expect(manager.playbackError?.contains("took too long") == true)
        #expect(!manager.hasActivePlayer)
        gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!manager.hasActivePlayer)
        #expect(!manager.isPlaying)
        #expect(manager.playbackError?.contains("took too long") == true)
        try await waitUntil { gate.closedSessionIDs.count == 1 }
        #expect(gate.closedSessionIDs == ["session-A"])
        await fixture.close()
    }

    @Test(arguments: [false, true]) func switchRejectsOldSessionAndOldError(fails: Bool) async throws {
        let fixture = try StartupFixture()
        let gate = StartupGate()
        let manager = fixture.manager
        manager.playBook(makeBook("A"), provider: StartupProviderStub(gate: gate, failsAfterRelease: fails))
        try await waitUntil { gate.entered }
        manager.playBook(makeBook("B"), provider: StartupProviderStub())
        try await waitUntil { !manager.isLoading && manager.playbackError != nil }
        let errorForB = manager.playbackError
        gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.currentBook?.id == "B")
        #expect(manager.playbackError == errorForB)
        if !fails { try await waitUntil { gate.closedSessionIDs.count == 1 } }
        #expect(gate.closedSessionIDs == (fails ? [] : ["session-A"]))
        #expect(!manager.hasActivePlayer)
        #expect(!manager.isPlaying)
        await fixture.close()
    }

    @Test func stopCancelsPendingBookWithoutPublishingFailure() async throws {
        let fixture = try StartupFixture()
        let gate = StartupGate()
        let manager = fixture.manager
        manager.playBook(makeBook("A"), provider: StartupProviderStub(gate: gate))
        try await waitUntil { gate.entered }
        manager.stop()
        gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.currentBook == nil)
        #expect(manager.playbackError == nil)
        #expect(!manager.isLoading)
        #expect(!manager.hasActivePlayer)
        await fixture.close()
    }

    @Test func pauseDuringStartupCanResumeWithoutAPlaybackError() async throws {
        let fixture = try StartupFixture(startupTimeout: 10)
        let file = fixture.root.appendingPathComponent("resume.wav")
        try PlaybackTestAudioFixture.wave(seconds: 90).write(to: file)
        let gate = StartupGate()
        let provider = StartupProviderStub(gate: gate, audioURL: file.absoluteString)
        let manager = fixture.manager
        manager.playBook(makeBook("A"), provider: provider)
        try await waitUntil { gate.entryCount == 1 }
        manager.pause()
        #expect(manager.playbackError == nil)
        #expect(!manager.isLoading)
        manager.play()
        try await waitUntil { gate.entryCount == 2 }
        gate.release()
        try await waitUntil { manager.isPlaying }
        #expect(manager.currentBook?.id == "A")
        #expect(manager.playbackError == nil)
        #expect(manager.hasActivePlayer)
        await fixture.close()
    }

    private func makeBook(_ id: String) -> Book {
        Book(id: id, title: "Fixture \(id)", duration: 90, source: .plex)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class StartupFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "startup-fixture-\(UUID().uuidString)"
    let session: ProfileSession
    let manager: PlaybackManager

    init(startupTimeout: TimeInterval = 0.1) throws {
        let id = UUID().uuidString
        let storage = ProfileStorageLocations(profileID: id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            cachesDirectory: root.appendingPathComponent("Caches"))
        session = try ProfileSession(profile: FamilyProfile(id: id, name: "Startup fixture", role: .child),
            storage: storage, defaults: UserDefaults(suiteName: suite))
        manager = PlaybackManager(profileSession: session, startupTimeout: startupTimeout, progressTimeout: 0.02)
    }

    func close() async {
        await manager.retire()
        await session.retire()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
