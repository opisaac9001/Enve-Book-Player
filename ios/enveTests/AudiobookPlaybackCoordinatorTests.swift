import Foundation
import Testing

@testable import enve

@MainActor
private final class DetailsGate {
    private(set) var waiting: Set<String> = []
    private var released: Set<String> = []
    private var continuations: [String: [CheckedContinuation<Void, Never>]] = [:]

    func wait(_ id: String) async {
        waiting.insert(id)
        guard !released.contains(id) else { return }
        await withCheckedContinuation { continuation in
            continuations[id, default: []].append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.release(id)
            }
        }
    }

    func release(_ id: String) {
        released.insert(id)
        continuations.removeValue(forKey: id)?.forEach { $0.resume() }
    }

    func releaseAll() {
        for id in continuations.keys { release(id) }
    }
}

private final class DetailsGateProvider: PlexProvider, @unchecked Sendable {
    let gate: DetailsGate

    init(connection: ServerConnection, gate: DetailsGate) {
        self.gate = gate
        super.init(connection: connection)
    }

    override func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        await gate.wait(bookId)
        return Book(id: bookId, title: "Fixture \(bookId)", duration: 90, chapters: [
            Chapter(id: "one", start: 0, end: 45, title: "One", index: 0),
            Chapter(id: "two", start: 45, end: 90, title: "Two", index: 1),
        ], source: .plex, providerId: connection.id, libraryId: "library")
    }

    override func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        PlaybackSessionInfo(sessionId: "session-\(book.id)", audioTracks: [], chapters: [])
    }

    override func performDataTask(for request: URLRequest, retryCount: Int = 3) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
@Suite(.serialized)
struct AudiobookPlaybackCoordinatorTests {
    @Test func lateDetailsForAnAbandonedBookDoNotReplaceTheNewBook() async throws {
        try await withFixture(detailsTimeout: 30) { fixture in
            try await waitUntil { NetworkPolicyService.shared.isConnected }
            fixture.coordinator.play(fixture.book("A"), presentPlayer: false)
            try await waitUntil { fixture.gate.waiting.contains("A") }
            fixture.coordinator.play(fixture.book("B"), presentPlayer: false)
            try await waitUntil { fixture.gate.waiting.contains("B") }
            try await Task.sleep(for: .milliseconds(100))
            #expect(fixture.manager.currentBook == nil)
            fixture.gate.release("B")
            try await waitUntil { fixture.manager.currentBook?.id == "B" }
            fixture.gate.release("A")
            try await Task.sleep(for: .milliseconds(200))
            #expect(fixture.manager.currentBook?.id == "B")
            #expect(fixture.session.appState.currentBook?.id == "B")
        }
    }

    @Test func detailsThatNeverReturnFallBackToTheCachedBookWithinTheBound() async throws {
        try await withFixture(detailsTimeout: 0.2) { fixture in
            try await waitUntil { NetworkPolicyService.shared.isConnected }
            let start = ContinuousClock.now
            fixture.coordinator.play(fixture.book("A"), presentPlayer: false)
            try await waitUntil { fixture.manager.currentBook?.id == "A" }
            #expect(ContinuousClock.now - start < .seconds(3))
            #expect(fixture.gate.waiting.contains("A"))
        }
    }

    @Test func placeholderChapterPlaysWithoutWaitingForDetails() async throws {
        try await withFixture(detailsTimeout: 30) { fixture in
            try await waitUntil { NetworkPolicyService.shared.isConnected }
            var book = fixture.book("A")
            book.duration = 3_600
            book.chapters = [Chapter(id: "full_book", start: 0, end: 3_600, title: book.title)]
            let start = ContinuousClock.now
            fixture.coordinator.play(book, presentPlayer: false)
            try await waitUntil { fixture.manager.currentBook?.id == "A" }
            #expect(ContinuousClock.now - start < .seconds(3))
        }
    }

    private func withFixture(
        detailsTimeout: TimeInterval,
        _ body: (CoordinatorFixture) async throws -> Void
    ) async throws {
        let fixture = try CoordinatorFixture(detailsTimeout: detailsTimeout)
        do {
            try await body(fixture)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
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
private final class CoordinatorFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "coordinator-fixture-\(UUID().uuidString)"
    let session: ProfileSession
    let manager: PlaybackManager
    let coordinator: AudiobookPlaybackCoordinator
    let gate = DetailsGate()
    let connection = ServerConnection(name: "Fixture", url: "https://fixture.invalid", type: .plex)

    init(detailsTimeout: TimeInterval) throws {
        let id = UUID().uuidString
        let storage = ProfileStorageLocations(profileID: id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            cachesDirectory: root.appendingPathComponent("Caches"))
        session = try ProfileSession(profile: FamilyProfile(id: id, name: "Coordinator fixture", role: .child),
            storage: storage, defaults: UserDefaults(suiteName: suite))
        session.providerConnections.connections = [connection]
        session.providerConnections[connection.id] = DetailsGateProvider(connection: connection, gate: gate)
        manager = PlaybackManager(profileSession: session, startupTimeout: 1, progressTimeout: 0.02)
        coordinator = AudiobookPlaybackCoordinator(appState: session.appState, playback: manager,
            profileSession: session, detailsTimeout: detailsTimeout)
    }

    func book(_ id: String) -> Book {
        Book(id: id, title: "Fixture \(id)", duration: 90, source: .plex, providerId: connection.id, libraryId: "library")
    }

    func close() async {
        gate.releaseAll()
        _ = try? await PlaybackStartupDeadline.run(seconds: 5) { [coordinator] in await coordinator.retire() }
        await manager.retire()
        await session.retire()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
