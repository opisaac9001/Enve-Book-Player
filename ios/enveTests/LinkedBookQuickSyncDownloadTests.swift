import Foundation
import Testing

@testable import enve

/// Quick Sync's download handoff against the real profile download queue, with a loopback transfer fixture.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LinkedBookQuickSyncDownloadTests {
    private let quickSync = LinkedBookQuickSyncService.shared

    @Test(arguments: [false, true])
    func restartingQuickSyncReusesCompletedAudioWithoutNetwork(legacyKey: Bool) async throws {
        let fixture = try DownloadLifecycleFixture()
        let providerID = UUID()
        let book = Book(id: "completed-audio", title: "Completed audio fixture", duration: 60,
            audioTracks: [AudioTrack(index: 0, title: "Track", contentUrl: "http://127.0.0.1:1/unused.mp3", duration: 60, startOffset: 0)],
            providerId: providerID, backendId: "completed-backend", source: .audiobookshelf)
        let storage = fixture.session.localStorage
        let key = legacyKey ? "audiobookshelf:\(providerID.uuidString):\(book.id)" : book.downloadKey
        let directory = storage.bookAudioDirectory(for: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("chapter_0.mp3")
        let bytes = Data(repeating: 65, count: 131_072)
        try bytes.write(to: file)
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        #expect(storage.isAudiobookDownloaded(book))

        for _ in 0..<3 {
            #expect(!quickSync.needsAudiobookDownload(book, profile: fixture.session))
            do {
                try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { _ in
                    Issue.record("Completed audio must not start another download")
                }
            } catch {
                Issue.record("Completed audio should be usable offline: \(error)")
            }
        }
        #expect(fixture.session.downloads.tasks.isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == modified)
        await fixture.close()
    }

    @Test func aStaleActiveEntryNeverHidesCompletedAudioOrRestartsIt() async throws {
        let providerID = UUID()
        let book = absBook("stale-entry", providerID: providerID, tracks: 1)
        var stale = BookDownloadTask.create(bookId: book.downloadKey, title: book.title, source: book.source)
        stale.status = .downloading
        stale.progress = 0.4
        let fixture = try DownloadLifecycleFixture(queue: [stale])
        let files = try writeAudio(for: book.downloadKey, count: 1, in: fixture.session)
        let before = try snapshot(files)
        // Listed as downloading, so it is not complete yet; no transfer is actually running.
        #expect(!fixture.session.downloads.hasCompleteAudio(for: book))

        for _ in 0..<3 {
            try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { _ in
                Issue.record("Completed audio must not start another download")
            }
            #expect(!quickSync.needsAudiobookDownload(book, profile: fixture.session))
        }
        #expect(fixture.session.downloads.tasks.filter { $0.bookId == book.downloadKey }.isEmpty)
        #expect(try snapshot(files) == before)
        await fixture.close()
    }

    @Test func aPartialMultiTrackDownloadIsNeverComplete() async throws {
        let fixture = try DownloadLifecycleFixture()
        let book = absBook("partial", providerID: UUID(), tracks: 3)
        let first = try writeAudio(for: book.downloadKey, count: 1, in: fixture.session)
        let partial = try snapshot(first)
        #expect(!fixture.session.downloads.hasCompleteAudio(for: book))
        #expect(quickSync.needsAudiobookDownload(book, profile: fixture.session))
        // Offline, so the honest result is a refusal; the partial file is left as it was.
        await #expect(throws: LinkedBookQuickSyncDownloadError.notStarted("No network connection")) {
            try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { _ in }
        }
        #expect(try snapshot(first) == partial)
        #expect(fixture.session.downloads.tasks.isEmpty)

        _ = try writeAudio(for: book.downloadKey, count: 3, in: fixture.session)
        #expect(fixture.session.downloads.hasCompleteAudio(for: book))
        await fixture.close()
    }

    @Test func anotherConnectionsFilesForTheSameItemIdAreNeverBorrowed() async throws {
        let fixture = try DownloadLifecycleFixture()
        let owner = absBook("shared-item", providerID: UUID(), tracks: 1)
        let other = absBook("shared-item", providerID: UUID(), tracks: 1)
        let ownerFiles = try writeAudio(for: "audiobookshelf:\(owner.providerId.uuidString):\(owner.id)", count: 1, in: fixture.session)
        let ownerBytes = try snapshot(ownerFiles)
        #expect(fixture.session.downloads.hasCompleteAudio(for: owner))
        #expect(!fixture.session.downloads.hasCompleteAudio(for: other))
        #expect(quickSync.needsAudiobookDownload(other, profile: fixture.session))

        // A bare item-id folder without metadata naming the book belongs to neither connection.
        let bare = absBook("bare-item", providerID: UUID(), tracks: 1)
        _ = try writeAudio(for: bare.id, count: 1, in: fixture.session)
        #expect(!fixture.session.downloads.hasCompleteAudio(for: bare))
        #expect(try snapshot(ownerFiles) == ownerBytes)
        await fixture.close()
    }

    @Test func anotherProfilesDownloadIsNotThisProfiles() async throws {
        let first = try DownloadLifecycleFixture()
        let second = try DownloadLifecycleFixture()
        let book = absBook("profile-isolated", providerID: UUID(), tracks: 1)
        _ = try writeAudio(for: book.downloadKey, count: 1, in: first.session)
        #expect(first.session.downloads.hasCompleteAudio(for: book))
        #expect(!second.session.downloads.hasCompleteAudio(for: book))
        #expect(quickSync.needsAudiobookDownload(book, profile: second.session))
        await first.close()
        await second.close()
    }

    @Test func aPausedTransferIsResumedInsteadOfDuplicated() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let book = Book(id: "paused-direct", title: "Paused fixture", duration: 30,
            audioTracks: [AudioTrack(id: "0", index: 0, title: "Track", contentUrl: "http://127.0.0.1:\(port)/hold-one.mp3", duration: 30, startOffset: 0)],
            providerId: UUID(), source: .realdebrid)
        try await fixture.startNetwork()
        let first = Task { await fixture.session.downloads.download(book: book) }
        try await waitUntil { server.heldCount > 0 }
        let id = try #require(fixture.session.downloads.tasks.first?.id)
        fixture.session.downloads.pause(taskId: id)
        await first.value

        let wait = Task { try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { _ in } }
        try await waitUntil { fixture.session.downloads.tasks.first?.status == .downloading }
        #expect(fixture.session.downloads.tasks.map(\.id) == [id])
        server.release()
        try await wait.value
        #expect(fixture.session.downloads.tasks.map(\.id) == [id])
        #expect(fixture.session.downloads.hasCompleteAudio(for: book))
        await fixture.close()
    }

    @Test func aTransferStillBeingSetUpIsJoinedNotDuplicated() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let gate = DownloadMetadataGate()
        let book = fixture.configure(gate: gate, urls: ["http://127.0.0.1:\(port)/ready.mp3"])
        try await fixture.startNetwork()
        let downloads = fixture.session.downloads
        let first = Task { await downloads.download(book: book) }
        // Waiting on provider metadata: queued, no URL task yet.
        try await waitUntil { gate.entered }
        let id = try #require(downloads.tasks.first?.id)
        #expect(downloads.hasLiveTransfer(forBookKey: book.downloadKey))

        let wait = Task { try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { _ in } }
        try await Task.sleep(for: .milliseconds(400))
        #expect(downloads.tasks.map(\.id) == [id])
        gate.release()
        try await wait.value
        await first.value
        #expect(downloads.tasks.map(\.id) == [id])
        #expect(downloads.hasCompleteAudio(for: book))
        await fixture.close()
    }

    @Test func aTransferRestoredAfterRelaunchIsJoinedNotReplaced() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let book = absBook("restored", providerID: UUID(), tracks: 1)
        var restored = BookDownloadTask.create(bookId: book.downloadKey, title: book.title, source: book.source)
        restored.status = .downloading
        restored.progress = 0.3
        let fixture = try DownloadLifecycleFixture(queue: [restored])
        let downloads = fixture.session.downloads
        // The background session kept this attempt running; another profile's queue id is not ours.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let live = session.downloadTask(with: URL(string: "http://127.0.0.1:\(port)/hold-restored.mp3")!)
        live.taskDescription = "\(restored.id)|\(book.downloadKey)|restored-attempt"
        let foreign = session.downloadTask(with: URL(string: "http://127.0.0.1:\(port)/hold-foreign.mp3")!)
        foreign.taskDescription = "\(UUID().uuidString)|\(book.downloadKey)|foreign-attempt"
        live.resume()
        foreign.resume()
        try await waitUntil { server.heldCount == 2 }
        downloads.transferInventoryOverride = { [live, foreign] in [foreign, live] }
        #expect(!downloads.hasLiveTransfer(forBookKey: book.downloadKey))

        // Offline: replacing the entry would end in a refusal; joining keeps waiting on the restored transfer.
        let wait = Task { try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { _ in } }
        try await waitUntil { downloads.hasLiveTransfer(forBookKey: book.downloadKey) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(downloads.tasks.map(\.id) == [restored.id])
        #expect(downloads.tasks.first?.status == .downloading)
        #expect(server.heldCount == 2)
        wait.cancel()
        await #expect(throws: CancellationError.self) { try await wait.value }
        server.release()
        await fixture.close()
    }

    @Test func aPriorAttemptsLateCallbacksNeverTouchTheCurrentAttempt() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let book = absBook("attempts", providerID: UUID(), tracks: 1)
        var entry = BookDownloadTask.create(bookId: book.downloadKey, title: book.title, source: book.source)
        entry.status = .downloading
        entry.progress = 0.4
        entry.bytesDownloaded = 40_000
        entry.totalBytes = 100_000
        let fixture = try DownloadLifecycleFixture(queue: [entry])
        let downloads = fixture.session.downloads
        let original = try writeAudio(for: book.downloadKey, count: 1, in: fixture.session)
        let originalBytes = try snapshot(original)

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let current = session.downloadTask(with: URL(string: "http://127.0.0.1:\(port)/hold-current.mp3")!)
        current.taskDescription = "\(entry.id)|\(book.downloadKey)|current"
        current.resume()
        try await waitUntil { server.heldCount == 1 }
        downloads.transferInventoryOverride = { [current] in [current] }
        await downloads.reconcileRestoredTransfers()
        #expect(downloads.hasLiveTransfer(forBookKey: book.downloadKey))

        let location = FileManager.default.temporaryDirectory.appendingPathComponent("prior-attempt-\(UUID().uuidString).mp3")
        for description in ["\(entry.id)|\(book.downloadKey)|earlier", "\(entry.id)|\(book.downloadKey)"] {
            let prior = session.downloadTask(with: URL(string: "http://127.0.0.1:\(port)/unused.mp3")!)
            prior.taskDescription = description
            downloads.urlSession(session, downloadTask: prior, didWriteData: 90_000, totalBytesWritten: 99_000, totalBytesExpectedToWrite: 100_000)
            try Data(repeating: 66, count: 200_000).write(to: location)
            downloads.urlSession(session, downloadTask: prior, didFinishDownloadingTo: location)
            downloads.urlSession(session, task: prior, didCompleteWithError: URLError(.timedOut))
        }
        try await Task.sleep(for: .milliseconds(300))
        let untouched = try #require(downloads.tasks.first)
        #expect(untouched.status == .downloading && untouched.progress == 0.4 && untouched.bytesDownloaded == 40_000)
        #expect(downloads.hasLiveTransfer(forBookKey: book.downloadKey))
        #expect(try snapshot(original) == originalBytes)

        // The current attempt is still heard.
        downloads.urlSession(session, downloadTask: current, didWriteData: 20_000, totalBytesWritten: 60_000, totalBytesExpectedToWrite: 100_000)
        try await waitUntil { downloads.tasks.first?.bytesDownloaded == 60_000 }

        // A removed entry is not brought back by its own attempt's completion.
        downloads.remove(taskId: entry.id)
        try Data(repeating: 67, count: 200_000).write(to: location)
        downloads.urlSession(session, downloadTask: current, didFinishDownloadingTo: location)
        try await Task.sleep(for: .milliseconds(300))
        #expect(downloads.tasks.isEmpty)
        #expect(try snapshot(original) == originalBytes)
        server.release()
        await fixture.close()
    }

    @Test func aPausedTransferResumesFromItsReceivedBytes() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        try await fixture.startNetwork()
        let book = Book(id: "range-episode", title: "Range fixture", partKey: "http://127.0.0.1:\(port)/range-episode.mp3",
            duration: 60, source: .local, isPodcastEpisode: true)
        let downloads = fixture.session.downloads
        let first = Task { await downloads.download(book: book) }
        try await waitUntil(seconds: 30) { (downloads.tasks.first?.bytesDownloaded ?? 0) > 0 }
        let id = try #require(downloads.tasks.first?.id)
        downloads.pause(taskId: id)
        await first.value

        let wait = Task { try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { _ in } }
        try await waitUntil(seconds: 20) { server.rangeRequests.count >= 2 }
        let requests = server.rangeRequests
        #expect(requests.first == "none")
        let resumedFrom = requests[1].split(separator: "=").last?.split(separator: "-").first.flatMap { Int($0) } ?? 0
        // A request without Range would be answered with the first half again and held; fail instead of waiting.
        guard resumedFrom > 0 else {
            Issue.record("The resumed request did not continue from the received bytes: \(requests[1])")
            wait.cancel()
            downloads.cancel(taskId: id)
            await fixture.close()
            return
        }
        try await wait.value
        #expect(downloads.tasks.map(\.id) == [id])
        let files = try #require(fixture.session.localStorage.localAudiobookFilesIfExists(for: book))
        #expect(files.count == 1)
        #expect(try Data(contentsOf: files[0]) == DownloadFixtureServer.rangePayload)
        await fixture.close()
    }

    @Test func aHeldTransferReportsProgressAndCompletesOnlyWithAllAudio() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        // Direct multi-file HTTP (Real-Debrid) reports a fraction per finished file; the Plex path reports none until done.
        let urls = ["ready", "hold-two"].map { "http://127.0.0.1:\(port)/\($0).mp3" }
        let book = Book(id: "quicksync-direct", title: "Direct download fixture", duration: 60,
            audioTracks: urls.enumerated().map {
                AudioTrack(id: "\($0.offset)", index: $0.offset, title: "Track", contentUrl: $0.element, duration: 30, startOffset: Double($0.offset * 30))
            },
            providerId: UUID(), source: .realdebrid)
        try await fixture.startNetwork()
        let reports = ProgressReports()

        let wait = Task { try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { reports.values.append($0) } }
        try await waitUntil { server.heldCount > 0 && reports.values.contains { $0 > 0 && $0 < 1 } }
        #expect(fixture.session.downloads.tasks.filter { $0.bookId == book.downloadKey }.count == 1)
        #expect(!fixture.session.downloads.hasCompleteAudio(for: book))
        #expect(quickSync.needsAudiobookDownload(book, profile: fixture.session))

        server.release()
        try await wait.value
        #expect(fixture.session.downloads.hasCompleteAudio(for: book))
        #expect(!quickSync.needsAudiobookDownload(book, profile: fixture.session))
        await fixture.close()
    }

    @Test func aRefusedRequestEndsPromptlyWithItsReason() async throws {
        let fixture = try DownloadLifecycleFixture()
        let book = fixture.configure(urls: ["http://127.0.0.1:1/unused.mp3"])
        // The network monitor is not started, so the download service refuses without queuing anything.
        let started = ContinuousClock.now
        await #expect(throws: LinkedBookQuickSyncDownloadError.notStarted("No network connection")) {
            try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { _ in }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(fixture.session.downloads.tasks.isEmpty)
        await fixture.close()
    }

    @Test(arguments: [true, false]) func pausingOrCancellingTheDownloadEndsTheWaitWithoutPartialAudio(pause: Bool) async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let book = fixture.configure(urls: ["ready", "hold-one"].map { "http://127.0.0.1:\(port)/\($0).mp3" })
        try await fixture.startNetwork()

        let wait = Task { try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { _ in } }
        try await waitUntil { server.heldCount > 0 }
        let id = try #require(fixture.session.downloads.tasks.first?.id)
        if pause { fixture.session.downloads.pause(taskId: id) } else { fixture.session.downloads.cancel(taskId: id) }
        await #expect(throws: pause ? LinkedBookQuickSyncDownloadError.paused : .cancelled) { try await wait.value }
        server.release()
        #expect(!fixture.session.downloads.hasCompleteAudio(for: book))
        await fixture.close()
    }

    @Test func retiringTheProfileEndsTheWait() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let book = fixture.configure(urls: ["ready", "hold-one"].map { "http://127.0.0.1:\(port)/\($0).mp3" })
        try await fixture.startNetwork()

        let wait = Task { try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { _ in } }
        try await waitUntil { server.heldCount > 0 }
        await fixture.session.retire()
        await #expect(throws: CancellationError.self) { try await wait.value }
        server.release()
        await fixture.close()
    }

    @Test func aDownloadRemovedFromTheListEndsTheWait() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let book = fixture.configure(urls: ["ready", "hold-one"].map { "http://127.0.0.1:\(port)/\($0).mp3" })
        try await fixture.startNetwork()

        let reports = ProgressReports()
        let wait = Task { try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { reports.values.append($0) } }
        // A progress report means the wait has observed the task, so its removal is classified as cancelled.
        try await waitUntil { server.heldCount > 0 && !reports.values.isEmpty }
        let id = try #require(fixture.session.downloads.tasks.first?.id)
        fixture.session.downloads.remove(taskId: id)
        await #expect(throws: LinkedBookQuickSyncDownloadError.cancelled) { try await wait.value }
        server.release()
        #expect(!fixture.session.downloads.hasCompleteAudio(for: book))
        await fixture.close()
    }

    @Test func aDownloadRemovedBeforeTheWaitObservesItStillEndsPromptly() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let book = fixture.configure(urls: ["hold-one"].map { "http://127.0.0.1:\(port)/\($0).mp3" })
        try await fixture.startNetwork()

        let wait = Task { try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { _ in } }
        try await waitUntil { !fixture.session.downloads.tasks.isEmpty }
        let id = try #require(fixture.session.downloads.tasks.first?.id)
        let started = ContinuousClock.now
        fixture.session.downloads.remove(taskId: id)
        // Unobserved, the removal looks like a request that never queued; either reason is truthful.
        do {
            try await wait.value
            Issue.record("A removed download completed the wait")
        } catch let error as LinkedBookQuickSyncDownloadError {
            switch error {
            case .cancelled, .notStarted: break
            default: Issue.record("Unexpected \(error)")
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        server.release()
        #expect(!fixture.session.downloads.hasCompleteAudio(for: book))
        await fixture.close()
    }

    @Test func aFailedTransferEndsTheWaitWithTheFailure() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let book = fixture.configure(urls: ["ready", "missing-two"].map { "http://127.0.0.1:\(port)/\($0).mp3" })
        try await fixture.startNetwork()
        do {
            try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { _ in }
            Issue.record("A refused connection completed the download")
        } catch let error as LinkedBookQuickSyncDownloadError {
            guard case .failed = error else { Issue.record("Unexpected \(error)"); return }
        }
        #expect(!fixture.session.downloads.hasCompleteAudio(for: book))
        await fixture.close()
    }

    @Test func anExistingDownloadIsJoinedAndCancellingTheWaitLeavesItRunning() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let book = fixture.configure(urls: ["ready", "hold-one"].map { "http://127.0.0.1:\(port)/\($0).mp3" })
        try await fixture.startNetwork()
        let userDownload = Task { await fixture.session.downloads.download(book: book) }
        try await waitUntil { server.heldCount > 0 }

        let wait = Task { try await quickSync.awaitCompleteAudio(for: book, profile: fixture.session) { _ in } }
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.session.downloads.tasks.count == 1)
        wait.cancel()
        await #expect(throws: CancellationError.self) { try await wait.value }
        #expect(fixture.session.downloads.tasks.first?.isActive == true)

        server.release()
        await userDownload.value
        #expect(fixture.session.downloads.hasCompleteAudio(for: book))
        await fixture.close()
    }

    private func absBook(_ id: String, providerID: UUID, tracks: Int) -> Book {
        Book(id: id, title: "Fixture \(id)", duration: Double(tracks * 30),
            audioTracks: (0..<tracks).map { AudioTrack(index: $0, title: "Track", contentUrl: "http://127.0.0.1:1/unused-\($0).mp3", duration: 30, startOffset: Double($0 * 30)) },
            providerId: providerID, backendId: "fixture-backend", source: .audiobookshelf)
    }

    /// Writes `count` finished chapter files under one storage key, as a completed download leaves them.
    private func writeAudio(for key: String, count: Int, in session: ProfileSession) throws -> [URL] {
        let directory = session.localStorage.bookAudioDirectory(for: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let file = directory.appendingPathComponent("chapter_\(index).mp3")
            if !FileManager.default.fileExists(atPath: file.path) { try Data(repeating: 65, count: 131_072).write(to: file) }
            return file
        }
    }

    private func snapshot(_ files: [URL]) throws -> [Data] {
        try files.map { file in
            let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
            return try Data(contentsOf: file) + Data("\(modified?.timeIntervalSince1970 ?? 0)".utf8)
        }
    }

    private final class ProgressReports {
        var values: [Double] = []
    }

    private func waitUntil(seconds: Int = 15, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
