import Foundation
import Testing

@testable import enve

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DownloadsEngineTaskListTests {
    @Test func aPausedDownloadStaysListedAndResumesOnlyWhenItsBookResolves() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let book = fixture.configure(urls: ["hold-one"].map { "http://127.0.0.1:\(port)/\($0).mp3" })
        try await fixture.startNetwork()
        let engine = DownloadsEngine(profileSession: fixture.session, service: fixture.session.downloads, appState: fixture.session.appState)

        let operation = Task { await fixture.session.downloads.download(book: book) }
        try await waitUntil { server.heldCount > 0 }
        let id = try #require(fixture.session.downloads.tasks.first?.id)
        fixture.session.downloads.pause(taskId: id)
        await operation.value
        #expect(engine.activeTasks.isEmpty)
        #expect(engine.pausedTasks.map(\.id) == [id])

        // Not in the store or memory: the row reports it rather than silently doing nothing.
        let paused = try #require(engine.pausedTasks.first)
        #expect(await engine.restart(paused) == false)
        #expect(engine.pausedTasks.map(\.id) == [id])

        fixture.session.appState.libraryCache.hot.insert(book)
        let resume = Task { await engine.restart(paused) }
        // The paused transfer's connection stays held, so the resumed request is the second one.
        try await waitUntil { engine.activeTasks.map(\.id) == [id] && server.heldCount >= 2 }
        server.release()
        #expect(await resume.value)
        #expect(engine.completedTasks.map(\.id) == [id])
        await fixture.close()
    }

    @Test func aCancelledDownloadStaysListedUntilCleared() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let book = fixture.configure(urls: ["hold-one"].map { "http://127.0.0.1:\(port)/\($0).mp3" })
        try await fixture.startNetwork()
        let engine = DownloadsEngine(profileSession: fixture.session, service: fixture.session.downloads, appState: fixture.session.appState)

        let operation = Task { await fixture.session.downloads.download(book: book) }
        try await waitUntil { server.heldCount > 0 }
        let id = try #require(fixture.session.downloads.tasks.first?.id)
        engine.cancel(taskId: id)
        await operation.value
        server.release()
        #expect(engine.cancelledTasks.map(\.id) == [id])
        engine.clearCompleted()
        #expect(engine.tasks.isEmpty)
        await fixture.close()
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
