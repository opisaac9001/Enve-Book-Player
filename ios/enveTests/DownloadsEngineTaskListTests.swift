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

    @Test func bulkControlsTargetOnlyTheirStatusesAndKeepMissingBooksActionable() async throws {
        let statuses: [BookDownloadTask.DownloadStatus] = [.queued, .downloading, .paused, .failed, .cancelled, .completed]
        let seeded = statuses.map { status -> BookDownloadTask in
            var task = BookDownloadTask.create(bookId: "seeded-\(status.rawValue)", title: status.rawValue, source: .plex)
            task.status = status
            return task
        }
        let ids = seeded.map(\.id)
        let (downloading, paused, failed) = (ids[1], ids[2], ids[3])
        let fixture = try DownloadLifecycleFixture(queue: seeded)
        let engine = DownloadsEngine(profileSession: fixture.session, service: fixture.session.downloads, appState: fixture.session.appState)

        #expect(engine.pausableTasks.map(\.id) == [ids[0], downloading])
        #expect(engine.resumableTasks.map(\.id) == [paused])
        #expect(engine.retryableTasks.map(\.id) == [failed])

        #expect(engine.pauseAll() == 2)
        #expect(engine.tasks.map(\.status) == [.paused, .paused, .paused, .failed, .cancelled, .completed])

        // None of the seeded books are in the library: the failed row is reported and kept, not dropped.
        let outcome = try #require(await engine.restartAll(.retry))
        #expect(outcome.started == 0)
        #expect(outcome.missingTaskIds == [failed])
        #expect(engine.tasksMissingBooks.map(\.id) == [failed])
        #expect(engine.retryableTasks.map(\.id) == [failed])
        #expect(engine.tasks.first { $0.id == failed }?.status == .failed)

        #expect(engine.removeTasksWithMissingBooks() == 1)
        #expect(engine.tasksMissingBooks.isEmpty)
        #expect(!engine.tasks.contains { $0.id == failed })
        #expect(engine.tasks.count == 5)
        await fixture.close()
    }

    @Test func resumeAllLaunchesPausedTransfersTogetherWithoutAwaitingThem() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let (engine, books) = try await pauseTwoDownloads(fixture: fixture, server: server, port: port)
        for book in books { fixture.session.appState.libraryCache.hot.insert(book) }

        // The server holds every transfer, so this only returns because neither restart is awaited.
        let outcome = try #require(await engine.restartAll(.resume))
        #expect(outcome.started == 2)
        #expect(outcome.missingTaskIds.isEmpty)
        #expect(engine.resumableTasks.isEmpty)
        #expect(await engine.restartAll(.resume) == nil)

        // Both paused connections stay held, so two more held requests mean both resumed at once.
        try await waitUntil { engine.activeTasks.count == 2 && server.heldCount >= 4 }
        server.release()
        try await waitUntil { engine.completedTasks.count == 2 }
        await fixture.close()
    }

    @Test func resumeAllStartsResolvableBooksAndReportsMissingOnes() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let (engine, books) = try await pauseTwoDownloads(fixture: fixture, server: server, port: port)
        fixture.session.appState.libraryCache.hot.insert(books[0])
        let missingId = try #require(engine.pausedTasks.first { $0.bookId == books[1].downloadKey }?.id)

        let outcome = try #require(await engine.restartAll(.resume))
        #expect(outcome.started == 1)
        #expect(outcome.missingTaskIds == [missingId])
        #expect(engine.tasksMissingBooks.map(\.id) == [missingId])
        #expect(engine.resumableTasks.map(\.id) == [missingId])

        try await waitUntil { engine.activeTasks.map(\.bookId) == [books[0].downloadKey] && server.heldCount >= 3 }
        #expect(engine.removeTasksWithMissingBooks() == 1)
        #expect(!engine.tasks.contains { $0.bookId == books[1].downloadKey })
        server.release()
        try await waitUntil { engine.completedTasks.map(\.bookId) == [books[0].downloadKey] }
        await fixture.close()
    }

    private func pauseTwoDownloads(fixture: DownloadLifecycleFixture, server: DownloadFixtureServer, port: UInt16) async throws -> (DownloadsEngine, [Book]) {
        let first = fixture.configure(urls: ["hold-one"].map { "http://127.0.0.1:\(port)/\($0).mp3" })
        let second = Book(id: "fixture-second", title: "Second download fixture", duration: 30,
            audioTracks: [AudioTrack(id: "0", index: 0, title: "Track", duration: 30, startOffset: 0)],
            providerId: first.providerId, source: .plex)
        try await fixture.startNetwork()
        let engine = DownloadsEngine(profileSession: fixture.session, service: fixture.session.downloads, appState: fixture.session.appState)
        let operations = [first, second].map { book in Task { await fixture.session.downloads.download(book: book) } }
        try await waitUntil { server.heldCount >= 2 && engine.pausableTasks.count == 2 }
        #expect(engine.pauseAll() == 2)
        for operation in operations { await operation.value }
        #expect(engine.activeTasks.isEmpty)
        #expect(engine.resumableTasks.count == 2)
        return (engine, [first, second])
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
