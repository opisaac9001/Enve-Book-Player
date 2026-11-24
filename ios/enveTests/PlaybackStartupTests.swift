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
    let serverResume: TimeInterval?
    var progressRequests = 0
    private(set) var playbackReports = 0

    init(
        gate: StartupGate? = nil,
        failsAfterRelease: Bool = false,
        audioURL: String = "file:///nonexistent-fixture.wav",
        serverResume: TimeInterval? = nil,
        connection: ServerConnection = ServerConnection(name: "Fixture", url: "https://fixture.invalid", type: .plex)
    ) {
        self.gate = gate
        self.failsAfterRelease = failsAfterRelease
        self.audioURL = audioURL
        self.serverResume = serverResume
        super.init(connection: connection)
    }

    override func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        await gate?.wait()
        if failsAfterRelease { throw URLError(.networkConnectionLost) }
        return PlaybackSessionInfo(
            sessionId: "session-\(book.id)",
            audioTracks: gate == nil ? [] : [AudioTrackInfo(index: 0, startOffset: 0, duration: 90,
                contentUrl: audioURL, mimeType: "audio/wav")],
            chapters: [],
            serverCurrentTime: serverResume
        )
    }

    override func reportPlayback(_ event: ServerPlaybackEvent, book: Book, sessionId: String, position: TimeInterval) async {
        playbackReports += 1
        if case .stopped = event { gate?.recordClose(sessionId) }
    }

    override func fetchAudiobookProgress(for book: Book) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isFinished: Bool)? {
        progressRequests += 1
        return (40, 40.0 / 90, 0, Date(), false)
    }

}

private final class TrackSwitchProviderStub: PlexProvider, @unchecked Sendable {
    let sessions: [[AudioTrackInfo]]
    let reopenGate: StartupGate?
    private(set) var events: [String] = []

    init(sessions: [[AudioTrackInfo]], reopenGate: StartupGate? = nil) {
        self.sessions = sessions
        self.reopenGate = reopenGate
        super.init(connection: ServerConnection(name: "Fixture", url: "https://fixture.invalid", type: .plex))
    }

    var openCount: Int { events.filter { $0.hasPrefix("open") }.count }

    override func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        let number = openCount + 1
        events.append("open session-\(number)")
        if number == 2 { await reopenGate?.wait() }
        return PlaybackSessionInfo(
            sessionId: "session-\(number)",
            audioTracks: sessions[min(number, sessions.count) - 1],
            chapters: [],
            serverCurrentTime: nil
        )
    }

    override func reportPlayback(_ event: ServerPlaybackEvent, book: Book, sessionId: String, position: TimeInterval) async {
        if case .stopped = event { events.append("close \(sessionId)") }
    }
}

private final class ResumeProgressProviderStub: PlexProvider, @unchecked Sendable {
    let tracks: [AudioTrackInfo]
    var remotePosition: TimeInterval = 65
    var remoteDate = Date().addingTimeInterval(60)
    var progressGate: StartupGate?
    var failsProgress = false
    var progressRequests = 0
    var resumedPositions: [TimeInterval] = []
    var started = false

    init(tracks: [AudioTrackInfo]) {
        self.tracks = tracks
        super.init(connection: ServerConnection(name: "Resume fixture", url: "https://fixture.invalid", type: .plex))
    }

    override func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        PlaybackSessionInfo(sessionId: "resume-\(book.id)", audioTracks: tracks, chapters: [])
    }

    override func fetchAudiobookProgress(for book: Book) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isFinished: Bool)? {
        progressRequests += 1
        await progressGate?.wait()
        if failsProgress { throw URLError(.notConnectedToInternet) }
        return (remotePosition, remotePosition / 90, nil, remoteDate, false)
    }

    override func reportPlayback(_ event: ServerPlaybackEvent, book: Book, sessionId: String, position: TimeInterval) async {
        if case .started = event { started = true }
        if case .resumed = event { resumedPositions.append(position) }
    }

    override func updatePlaybackProgress(book: Book, sessionId: String?, currentTime: TimeInterval, isFinished: Bool, timeListened: TimeInterval) async throws {}
}

@MainActor
@Suite(.serialized)
struct PlaybackStartupTests {
    @Test(arguments: [false, true])
    func failedSecondFileKeepsTheRealPositionAndTrack(relative: Bool) async throws {
        try await withFixture(startupTimeout: 30) { fixture in
            let first = fixture.root.appendingPathComponent("part-1.wav")
            try PlaybackTestAudioFixture.wave(seconds: 45).write(to: first)
            let missing = fixture.root.appendingPathComponent("part-2.wav")
            let provider = TrackSwitchProviderStub(sessions: [
                twoTracks(first.absoluteString, missing.absoluteString, secondDuration: relative ? 0 : 45)
            ])
            let book = makeBook("failed-second")
            let manager = fixture.manager
            manager.playBook(book, provider: provider, startPosition: 40)
            try await waitUntil { manager.isPlaying && manager.livePosition != nil }

            if relative { manager.skipForward(seconds: 30) } else { manager.seek(to: 60) }
            #expect(manager.currentTime > 45)
            try await waitUntil { manager.playbackError != nil }

            let live = try #require(manager.livePosition)
            #expect(live >= 39 && live < 45)
            #expect(abs(manager.currentTime - live) < 1.5)
            #expect(!manager.isPlaying)
            #expect(provider.openCount == 1)
            #expect(try #require(fixture.session.bookProgress.loadProgress(for: book)).progress < 45)

            manager.seek(to: 10)
            try await waitUntil { manager.livePosition.map { abs($0 - 10) < 1 } == true }
        }
    }

    @Test(arguments: [false, true])
    func remoteTrackFailureReopensTheSessionOnceAfterClosingTheOldOne(naturalTransition: Bool) async throws {
        try await withFixture(startupTimeout: 30) { fixture in
            let first = fixture.root.appendingPathComponent("part-1.wav")
            let second = fixture.root.appendingPathComponent("part-2.wav")
            try PlaybackTestAudioFixture.wave(seconds: 45).write(to: first)
            try PlaybackTestAudioFixture.wave(seconds: 45).write(to: second)
            let provider = TrackSwitchProviderStub(sessions: [
                twoTracks(first.absoluteString, "https://fixture.invalid/part-2.wav"),
                twoTracks(first.absoluteString, second.absoluteString)
            ])
            let manager = fixture.manager
            manager.playBook(makeBook("remote-retry"), provider: provider, startPosition: naturalTransition ? 44 : 40)
            try await waitUntil { manager.isPlaying && manager.livePosition != nil }

            let target = naturalTransition ? 45.0 : 60.0
            if !naturalTransition { manager.seek(to: target) }
            try await waitUntil {
                manager.playbackError != nil || (provider.openCount == 2 && manager.livePosition.map { $0 >= target - 0.5 } == true)
            }

            #expect(manager.playbackError == nil)
            #expect(manager.isPlaying)
            #expect(provider.events == ["open session-1", "close session-1", "open session-2"])
            #expect(try #require(manager.livePosition) < target + 3)
        }
    }

    @Test func pauseDuringSessionRefreshDiscardsTheLateSession() async throws {
        try await withFixture(startupTimeout: 30) { fixture in
            let first = fixture.root.appendingPathComponent("part-1.wav")
            let second = fixture.root.appendingPathComponent("part-2.wav")
            try PlaybackTestAudioFixture.wave(seconds: 45).write(to: first)
            try PlaybackTestAudioFixture.wave(seconds: 45).write(to: second)
            let gate = StartupGate()
            let provider = TrackSwitchProviderStub(sessions: [
                twoTracks(first.absoluteString, "https://fixture.invalid/part-2.wav"),
                twoTracks(first.absoluteString, second.absoluteString)
            ], reopenGate: gate)
            let book = makeBook("refresh-cancel")
            let manager = fixture.manager
            manager.playBook(book, provider: provider, startPosition: 40)
            try await waitUntil { manager.isPlaying && manager.livePosition != nil }

            manager.seek(to: 60)
            try await waitUntil { gate.entered }
            #expect(provider.events == ["open session-1", "close session-1", "open session-2"])
            manager.pause()
            #expect(manager.currentTime < 45)
            gate.release()
            try await waitUntil { provider.events.last == "close session-2" }

            #expect(manager.playbackError == nil)
            #expect(!manager.isPlaying)
            let live = try #require(manager.livePosition)
            #expect(live >= 39 && live < 45)
            #expect(try #require(fixture.session.bookProgress.loadProgress(for: book)).progress < 45)

            manager.play()
            try await waitUntil { manager.isPlaying && manager.livePosition != nil }
            #expect(provider.openCount == 3)
            #expect(try #require(manager.livePosition) < 46)
        }
    }

    @Test(arguments: [0.0, 3.0])
    func explicitStartNearTheBeginningWinsOverTheServerSession(_ position: TimeInterval) async throws {
        try await withFixture(startupTimeout: 30) { fixture in
            fixture.session.defaults.set(true, forKey: "profileServerSyncEnabled")
            let file = fixture.root.appendingPathComponent("explicit-start.wav")
            try PlaybackTestAudioFixture.wave(seconds: 90).write(to: file)
            let gate = StartupGate()
            let provider = StartupProviderStub(gate: gate, audioURL: file.absoluteString, serverResume: 35)
            let book = makeBook("explicit-start")
            fixture.manager.playBook(book, provider: provider, startPosition: position)
            try await waitUntil { gate.entered }
            gate.release()
            try await waitUntil {
                fixture.manager.playbackError != nil || (fixture.manager.isPlaying && !fixture.manager.isLoading)
            }
            try #require(fixture.manager.playbackError == nil)
            #expect(fixture.manager.currentTime >= position)
            #expect(fixture.manager.currentTime < position + 2)
            #expect(provider.progressRequests == 0)
        }
    }

    @Test(arguments: [0.0, 3.0], [false, true])
    func explicitStartsReachDirectAndLocalPlayback(_ position: TimeInterval, local: Bool) async throws {
        try await withFixture(startupTimeout: 30) { fixture in
            let file = fixture.root.appendingPathComponent("explicit-local.wav")
            try PlaybackTestAudioFixture.wave(seconds: 90).write(to: file)
            let book = Book(id: "explicit-local", title: "Explicit local", duration: 90, source: .local, filePath: file.path)
            fixture.session.bookProgress.saveProgress(for: book, progress: 35, duration: 90)

            if local {
                fixture.manager.playLocalBook(book, startPosition: position)
            } else {
                fixture.manager.playDirectURL(book, url: file, startPosition: position)
            }
            try await waitUntil { fixture.manager.isPlaying && !fixture.manager.isLoading }
            #expect(fixture.manager.currentTime >= position)
            #expect(fixture.manager.currentTime < position + 2)
        }
    }

    @Test func aRefusedStartNeverLeavesAPositionForTheNextRequest() async throws {
        try await withFixture(startupTimeout: 30) { fixture in
            let book = makeBook("refused-explicit")
            let starter = fixture.starter
            starter.play(book, from: 70, presentPlayer: false)
            #expect(fixture.manager.currentBook == nil)

            fixture.session.bookProgress.saveProgress(for: book, progress: 20, duration: 90)
            let file = fixture.root.appendingPathComponent("after-refusal.wav")
            try PlaybackTestAudioFixture.wave(seconds: 90).write(to: file)
            let gate = StartupGate()
            let provider = StartupProviderStub(gate: gate, audioURL: file.absoluteString)
            fixture.manager.playBook(book, provider: provider)
            try await waitUntil { gate.entered }
            gate.release()
            try await waitUntil { fixture.manager.isPlaying && !fixture.manager.isLoading }
            #expect(fixture.manager.currentTime >= 20 && fixture.manager.currentTime < 22)
        }
    }

    @Test(arguments: [false, true], [Book.BookSource.audiobookshelf, .plex])
    func downloadedBooksResumeWithoutWaitingForServerProgress(useCoordinator: Bool, source: Book.BookSource) async throws {
        try await withFixture(startupTimeout: 30) { fixture in
            fixture.session.defaults.set(true, forKey: "profileServerSyncEnabled")
            try await waitUntil { NetworkPolicyService.shared.isConnected }
            let connection = ServerConnection(name: "Download fixture", url: "https://fixture.invalid", type: source == .plex ? .plex : .audiobookshelf)
            let provider = StartupProviderStub(connection: connection)
            fixture.session.providerConnections.connections = [connection]
            fixture.session.providerConnections[connection.id] = provider
            let book = Book(
                id: "downloaded", title: "Downloaded book", duration: 90,
                chapters: [Chapter(id: "1", start: 0, end: 90, title: "Chapter 1", index: 0)],
                source: source, currentTime: 20, providerId: connection.id
            )
            let directory = fixture.session.localStorage.bookAudioDirectory(for: book.downloadKey)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PlaybackTestAudioFixture.wave(seconds: 90).write(to: directory.appendingPathComponent("chapter_0.wav"))

            let starter = fixture.starter
            if useCoordinator {
                starter.play(book, presentPlayer: false)
            } else {
                fixture.manager.playBook(book, provider: provider)
            }

            try await waitUntil { fixture.manager.isPlaying && !fixture.manager.isLoading }
            #expect(provider.progressRequests == 0)
            #expect(fixture.manager.currentTime >= 20 && fixture.manager.currentTime < 22)
            #expect(fixture.manager.playbackError == nil)
            #expect(fixture.session.pendingSync.entries[book.stableId]?.downloadedBaseline?.position == 20)
            #expect(provider.playbackReports == 0)
        }
    }

    @Test func downloadedPlaybackCannotOverwriteNewerProgressOnASiblingEdition() async throws {
        try await withFixture(startupTimeout: 30) { fixture in
            let session = fixture.session
            session.defaults.set(true, forKey: "profileServerSyncEnabled")
            let connection = ServerConnection(name: "Sibling fixture", url: "https://fixture.invalid", type: .audiobookshelf)
            let provider = ProgressProviderStub(connection: connection)
            session.providerConnections.connections = [connection]
            session.providerConnections[connection.id] = provider
            session.configureSyncPlugins()
            let source = Book(id: "downloaded-edition", title: "Fixture Audiobook", author: "Fixture Author", duration: 100)
            let target = Book(
                id: "server-edition", title: source.title, author: source.author, duration: 100, source: .audiobookshelf,
                currentTime: 10, lastUpdate: Date(timeIntervalSince1970: 100), providerId: connection.id
            )
            try #require(WorkIdentity.editionKey(for: source) == WorkIdentity.editionKey(for: target))
            await session.bookStore.upsertBooks([source, target])
            let directory = session.localStorage.bookAudioDirectory(for: source.downloadKey)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PlaybackTestAudioFixture.wave(seconds: 20).write(to: directory.appendingPathComponent("chapter_0.wav"))
            provider.audiobookProgress = ProviderAudiobookProgress(
                positionSeconds: 50, percentage: 0.5, trackIndex: nil,
                updatedAt: Date(timeIntervalSince1970: 200), readState: .reading
            )

            await session.playback.workProgress.fanOut(from: source, fraction: 0.3, isFinished: false, force: true)

            #expect(provider.playbackUpdates.isEmpty)
            #expect(session.pendingSync.entries[target.stableId]?.downloadedBaseline?.position == 10)
        }
    }

    @Test func changingPlaybackBooksRefreshesBookmarksWithoutReopeningThePlayer() async throws {
        try await withFixture(startupTimeout: 30) { fixture in
            let session = fixture.session
            let first = Book(id: "bookmarked", title: "Bookmarked", duration: 20)
            let second = Book(id: "unmarked", title: "Unmarked", duration: 20)
            for book in [first, second] {
                let directory = session.localStorage.bookAudioDirectory(for: book.downloadKey)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try PlaybackTestAudioFixture.wave(seconds: 20).write(to: directory.appendingPathComponent("chapter_0.wav"))
            }
            let bookmark = Bookmark(bookId: first.stableId, position: 10, title: "Saved moment")
            session.readerArtifacts.saveBookmarks(bookId: first.stableId, bookmarks: [bookmark])
            let player = session.playback.player
            let manager = session.playback.manager

            manager.playLocalBook(first)
            try await waitUntil { player.bookmarks == [bookmark] }
            manager.playLocalBook(second)
            try await waitUntil { player.bookmarks.isEmpty && manager.currentBook?.stableId == second.stableId }
            manager.playLocalBook(first)
            try await waitUntil { player.bookmarks == [bookmark] }
        }
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
        try await withFixture() { fixture in
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
        }
    }

    @Test(arguments: [false, true]) func switchRejectsOldSessionAndOldError(fails: Bool) async throws {
        try await withFixture() { fixture in
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
        }
    }

    @Test func stopCancelsPendingBookWithoutPublishingFailure() async throws {
        try await withFixture() { fixture in
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
        }
    }

    @Test func pauseDuringStartupCanResumeWithoutAPlaybackError() async throws {
        try await withFixture(startupTimeout: 30) { fixture in
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
        }
    }

    @Test(arguments: ["resume", "play", "same-book"], [0.0, 15.0, 65.0])
    func pausedPlexPlaybackReadsOtherClientsPositionBeforeReportingResume(entry: String, remote: TimeInterval) async throws {
        try await withPausedPlex { fixture, provider, book in
            provider.remotePosition = remote
            switch entry {
            case "resume": fixture.manager.resume()
            case "play": fixture.manager.play()
            default: fixture.manager.playBook(book, provider: provider)
            }
            try await waitUntil {
                !provider.resumedPositions.isEmpty && fixture.manager.livePosition.map { abs($0 - remote) < 2 } == true
            }
            #expect(provider.progressRequests == 1)
            #expect(abs(try #require(provider.resumedPositions.last) - remote) < 1)
            #expect(fixture.manager.isPlaying)
        }
    }

    @Test(arguments: [false, true])
    func explicitPausedSeekWinsOverPlexProgress(reopen: Bool) async throws {
        try await withPausedPlex { fixture, provider, book in
            if reopen {
                fixture.manager.playBook(book, provider: provider, startPosition: 5)
            } else {
                fixture.manager.seek(to: 5)
                fixture.manager.resume()
            }
            try await waitUntil { fixture.manager.isPlaying && !provider.resumedPositions.isEmpty }
            #expect(provider.progressRequests == 0)
            #expect(abs(try #require(provider.resumedPositions.last) - 5) < 1)
        }
    }

    @Test(arguments: ["older-server", "offline", "sync-disabled"])
    func pausedLocalPositionSurvivesUnavailableOrOlderPlexProgress(reason: String) async throws {
        try await withPausedPlex { fixture, provider, _ in
            switch reason {
            case "older-server": provider.remoteDate = Date().addingTimeInterval(-600)
            case "offline": provider.failsProgress = true
            default: fixture.session.defaults.set(false, forKey: "profileServerSyncEnabled")
            }
            fixture.manager.resume()
            try await waitUntil { fixture.manager.isPlaying && !fixture.manager.isLoading }
            #expect(provider.progressRequests == (reason == "sync-disabled" ? 0 : 1))
            #expect(try #require(fixture.manager.livePosition) < 43)
            #expect(try #require(fixture.manager.livePosition) >= 39)
        }
    }

    @Test(arguments: [false, true])
    func pauseOrSeekCancelsPendingPlexResume(seek: Bool) async throws {
        try await withPausedPlex { fixture, provider, _ in
            let gate = StartupGate()
            provider.progressGate = gate
            fixture.manager.resume()
            try await waitUntil { gate.entered }
            if seek { fixture.manager.seek(to: 7) } else { fixture.manager.pause() }
            gate.release()
            try await Task.sleep(for: .milliseconds(100))
            #expect(!fixture.manager.isPlaying)
            #expect(!fixture.manager.isLoading)
            #expect(provider.resumedPositions.isEmpty)
            #expect(abs(try #require(fixture.manager.livePosition) - (seek ? 7 : 40)) < 2)
        }
    }

    private func withPausedPlex(
        operation: (StartupFixture, ResumeProgressProviderStub, Book) async throws -> Void
    ) async throws {
        try await withFixture(startupTimeout: 30, progressTimeout: 1) { fixture in
            fixture.session.defaults.set(true, forKey: "profileServerSyncEnabled")
            let first = fixture.root.appendingPathComponent("resume-first.wav")
            let second = fixture.root.appendingPathComponent("resume-second.wav")
            try PlaybackTestAudioFixture.wave(seconds: 45).write(to: first)
            try PlaybackTestAudioFixture.wave(seconds: 45).write(to: second)
            let provider = ResumeProgressProviderStub(tracks: twoTracks(first.absoluteString, second.absoluteString))
            let book = makeBook("plex-handoff")
            fixture.session.providerConnections[book.providerId] = provider
            fixture.manager.playBook(book, provider: provider, startPosition: 40)
            try await waitUntil { provider.started && fixture.manager.livePosition != nil }
            fixture.manager.pause()
            try await operation(fixture, provider, book)
        }
    }

    private func withFixture(
        startupTimeout: TimeInterval = 0.1,
        progressTimeout: TimeInterval = 0.02,
        operation: (StartupFixture) async throws -> Void
    ) async throws {
        let fixture = try StartupFixture(startupTimeout: startupTimeout, progressTimeout: progressTimeout)
        do {
            try await operation(fixture)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func twoTracks(_ first: String, _ second: String, secondDuration: TimeInterval = 45) -> [AudioTrackInfo] {
        [
            AudioTrackInfo(index: 0, startOffset: 0, duration: 45, contentUrl: first, mimeType: "audio/wav"),
            AudioTrackInfo(index: 1, startOffset: 45, duration: secondDuration, contentUrl: second, mimeType: "audio/wav"),
        ]
    }

    private func makeBook(_ id: String) -> Book {
        Book(id: id, title: "Fixture \(id)", duration: 90, source: .plex)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
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
    lazy var starter = AudiobookPlaybackCoordinator(
        appState: session.appState, playback: manager, profileSession: session
    )

    init(startupTimeout: TimeInterval = 0.1, progressTimeout: TimeInterval = 0.02) throws {
        let id = UUID().uuidString
        let storage = ProfileStorageLocations(profileID: id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            cachesDirectory: root.appendingPathComponent("Caches"))
        session = try ProfileSession(profile: FamilyProfile(id: id, name: "Startup fixture", role: .child),
            storage: storage, defaults: UserDefaults(suiteName: suite))
        manager = PlaybackManager(profileSession: session, startupTimeout: startupTimeout, progressTimeout: progressTimeout)
    }

    func close() async {
        await starter.retire()
        await manager.retire()
        await session.retire()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
