import Foundation
import Testing

@testable import enve

struct DownloadStallTrackerTests {
    private let start = ContinuousClock.now

    private func at(_ seconds: Int) -> ContinuousClock.Instant { start.advanced(by: .seconds(seconds)) }

    @Test func threeRunsEndingAtTheSameByteStall() {
        var tracker = DownloadStallTracker()
        tracker.register("book", host: "server", at: at(0))
        #expect(tracker.recordBytes("book", written: 500, total: 500, at: at(1)) == nil)
        #expect(tracker.recordResume("book", offset: 500) == nil)
        #expect(tracker.recordResume("book", offset: 500) == nil)
        #expect(tracker.recordResume("book", offset: 500) == nil)
        #expect(tracker.recordResume("book", offset: 500) == .repeatedRuns)
        #expect(tracker.isEmpty)
        #expect(tracker.recordResume("book", offset: 500) == nil)
    }

    @Test func aSingleNewByteResetsTheRepeatCount() {
        var tracker = DownloadStallTracker()
        tracker.register("book", host: "server", at: at(0))
        _ = tracker.recordBytes("book", written: 500, total: 500, at: at(1))
        for _ in 0..<3 { #expect(tracker.recordResume("book", offset: 500) == nil) }
        _ = tracker.recordBytes("book", written: 1, total: 501, at: at(2))
        for _ in 0..<3 { #expect(tracker.recordResume("book", offset: 501) == nil) }
        #expect(tracker.recordResume("book", offset: 501) == .repeatedRuns)
    }

    @Test func identicalSingleChunkRestartsStallWithoutResumeCallbacks() {
        var tracker = DownloadStallTracker()
        tracker.register("book", host: "server", at: at(0))
        for second in 1...4 {
            #expect(tracker.recordBytes("book", written: 1000, total: 1000, at: at(second)) == nil)
        }
        #expect(tracker.recordBytes("book", written: 1000, total: 1000, at: at(5)) == .repeatedRuns)
    }

    @Test func weakerConnectionRunsDoNotCountAsASameByteStall() {
        var tracker = DownloadStallTracker()
        tracker.register("book", host: "server", at: at(0))
        #expect(tracker.recordBytes("book", written: 1000, total: 1000, at: at(1)) == nil)
        for second in 2...10 {
            #expect(tracker.recordBytes("book", written: 400, total: 400, at: at(second)) == nil)
        }
        #expect(!tracker.isEmpty)
    }

    @Test func theFirstResumeOfResumeDataOnlySetsTheStartingPoint() {
        var tracker = DownloadStallTracker()
        tracker.register("book", host: "server", at: at(0))
        for _ in 0..<3 { #expect(tracker.recordResume("book", offset: 4096) == nil) }
        #expect(tracker.recordResume("book", offset: 4096) == .repeatedRuns)
    }

    @Test func runsThatOverlapAnOfflinePeriodAreNotCounted() {
        var tracker = DownloadStallTracker()
        tracker.register("book", host: "server", at: at(0))
        _ = tracker.recordBytes("book", written: 500, total: 500, at: at(1))
        #expect(tracker.recordResume("book", offset: 500) == nil)
        tracker.setOnline(false, at: at(2))
        for _ in 0..<5 { #expect(tracker.recordResume("book", offset: 500) == nil) }
        tracker.setOnline(true, at: at(3))
        // The run that began offline is still excused; the following three count.
        for _ in 0..<3 { #expect(tracker.recordResume("book", offset: 500) == nil) }
        #expect(tracker.recordResume("book", offset: 500) == .repeatedRuns)
    }

    @Test func aSilentServerFailsOnlyItsOwnTransfersOnce() {
        var tracker = DownloadStallTracker()
        tracker.register("a", host: "silent", at: at(0))
        tracker.register("b", host: "silent", at: at(0))
        tracker.register("c", host: "busy", at: at(0))
        _ = tracker.recordBytes("c", written: 10, total: 10, at: at(100))
        #expect(tracker.silentTransfers(at: at(119)).isEmpty)
        #expect(Set(tracker.silentTransfers(at: at(120))) == ["a", "b"])
        #expect(tracker.silentTransfers(at: at(219)).isEmpty)
        #expect(tracker.silentTransfers(at: at(220)) == ["c"])
        #expect(tracker.isEmpty)
    }

    @Test func progressOnAPeerKeepsAQueuedTransferOnTheSameHostAlive() {
        var tracker = DownloadStallTracker()
        tracker.register("active", host: "server", at: at(0))
        tracker.register("queued", host: "server", at: at(0))
        for second in stride(from: 100, through: 1000, by: 100) {
            _ = tracker.recordBytes("active", written: 1, total: Int64(second), at: at(second))
            #expect(tracker.silentTransfers(at: at(second + 99)).isEmpty)
        }
        tracker.remove("active")
        #expect(tracker.silentTransfers(at: at(1119)).isEmpty)
        #expect(tracker.silentTransfers(at: at(1120)) == ["queued"])
    }

    @Test func steadySlowProgressNeverStalls() {
        var tracker = DownloadStallTracker()
        tracker.register("book", host: "server", at: at(0))
        for step in 1...30 {
            let second = step * 115
            #expect(tracker.recordBytes("book", written: 1, total: Int64(step), at: at(second)) == nil)
            #expect(tracker.silentTransfers(at: at(second + 114)).isEmpty)
        }
    }

    @Test func backgroundAndOfflineGapsRestartTheSilenceWindow() {
        var tracker = DownloadStallTracker()
        tracker.register("book", host: "server", at: at(0))
        tracker.setForeground(false, at: at(100))
        #expect(tracker.silentTransfers(at: at(900)).isEmpty)
        tracker.setForeground(true, at: at(1000))
        #expect(tracker.silentTransfers(at: at(1119)).isEmpty)
        tracker.setOnline(false, at: at(1119))
        #expect(tracker.silentTransfers(at: at(2000)).isEmpty)
        tracker.setOnline(true, at: at(2000))
        #expect(tracker.silentTransfers(at: at(2119)).isEmpty)
        #expect(tracker.silentTransfers(at: at(2120)) == ["book"])
    }

    @Test func removedTransfersAreNeverReportedAndANewTransferGetsAFreshWindow() {
        var tracker = DownloadStallTracker()
        tracker.register("paused", host: "server", at: at(0))
        tracker.register("running", host: "server", at: at(0))
        tracker.remove("paused")
        #expect(tracker.silentTransfers(at: at(120)) == ["running"])
        tracker.register("retried", host: "server", at: at(130))
        #expect(tracker.recordBytes("paused", written: 1, total: 1, at: at(131)) == nil)
        #expect(tracker.silentTransfers(at: at(249)).isEmpty)
        #expect(tracker.silentTransfers(at: at(250)) == ["retried"])
    }
}

struct DownloadStallMonitorTests {
    @Test func aStalledTaskIsReportedOnceWithItsReason() {
        let clock = StallTestClock()
        let monitor = DownloadStallMonitor(now: { clock.now })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let silent = StallRecorder()
        let repeating = StallRecorder()
        let silentTask = Self.task("silent", host: "silent.invalid", in: session)
        let repeatingTask = Self.task("repeating", host: "busy.invalid", in: session)
        monitor.track(silentTask) { silent.record($0) }
        monitor.track(repeatingTask) { repeating.record($0) }

        monitor.recordProgress(of: repeatingTask, bytesWritten: 64, totalBytesWritten: 64)
        for _ in 0..<5 { monitor.recordResume(of: repeatingTask, offset: 64) }
        #expect(repeating.stalls == [.repeatedRuns])

        clock.advance(seconds: 119)
        #expect(monitor.evaluate() == true)
        #expect(silent.stalls.isEmpty)
        clock.advance(seconds: 1)
        #expect(monitor.evaluate() == false)
        monitor.evaluate()
        #expect(silent.stalls == [.serverSilent])
    }

    @Test func stoppedTasksAndARetiredMonitorNeverReport() {
        let clock = StallTestClock()
        let monitor = DownloadStallMonitor(now: { clock.now })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let recorder = StallRecorder()
        let paused = Self.task("paused", host: "server.invalid", in: session)
        let retired = Self.task("retired", host: "server.invalid", in: session)
        monitor.track(paused) { recorder.record($0) }
        monitor.track(retired) { recorder.record($0) }
        monitor.stopTracking(paused)
        monitor.retire()
        monitor.track(paused) { recorder.record($0) }
        clock.advance(seconds: 600)
        #expect(monitor.evaluate() == false)
        for _ in 0..<5 { monitor.recordResume(of: retired, offset: 0) }
        #expect(recorder.stalls.isEmpty)
    }

    @Test func foregroundAndConnectivityGateServerSilence() {
        let clock = StallTestClock()
        let monitor = DownloadStallMonitor(now: { clock.now })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let recorder = StallRecorder()
        monitor.track(Self.task("book", host: "server.invalid", in: session)) { recorder.record($0) }
        monitor.setForeground(false)
        clock.advance(seconds: 600)
        monitor.evaluate()
        monitor.setForeground(true)
        monitor.setOnline(false)
        clock.advance(seconds: 600)
        monitor.evaluate()
        monitor.setOnline(true)
        clock.advance(seconds: 119)
        monitor.evaluate()
        #expect(recorder.stalls.isEmpty)
        clock.advance(seconds: 1)
        monitor.evaluate()
        #expect(recorder.stalls == [.serverSilent])
    }

    private static func task(_ description: String, host: String, in session: URLSession) -> URLSessionDownloadTask {
        let task = session.downloadTask(with: URL(string: "http://\(host)/\(description).mp3")!)
        task.taskDescription = description
        return task
    }
}

@MainActor
@Suite(.serialized)
struct DownloadStallIntegrationTests {
    @Test func repeatedRunsFailTheAudiobookTransferAndANewAttemptCompletes() async throws {
        let fixture = try DownloadLifecycleFixture()
        let storage = fixture.session.localStorage
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        let nativeSession = URLSession(configuration: .ephemeral)
        defer { nativeSession.invalidateAndCancel(); server.stop() }
        let store = BookHTTPTransferStore(storage: storage.profileStorageLocations, audioRoot: storage.audiobooksDirectory)
        let transfer = try store.begin(bookID: "stalled-book", destination: storage.bookAudioDirectory(for: "stalled-book"), mode: .single, count: 1)
        let native = nativeSession.downloadTask(with: URL(string: "http://127.0.0.1:\(port)/hold-stalled.mp3")!)
        native.taskDescription = transfer.taskDescription(for: 0)
        let manager = BookDownloadManager(storage: storage, activity: ProfileDownloadActivity(),
            stallMonitor: DownloadStallMonitor(now: StallTestClock().nowProvider), clientCertificate: { _ in nil })
        manager.transferInventoryOverride = { [native] in [native] }
        await manager.restoreTransfers()
        #expect(manager.activeBookIds == [transfer.bookID])

        manager.urlSession(nativeSession, downloadTask: native, didWriteData: 2048, totalBytesWritten: 2048, totalBytesExpectedToWrite: 8192)
        for _ in 0..<3 { manager.urlSession(nativeSession, downloadTask: native, didResumeAtOffset: 2048, expectedTotalBytes: 8192) }
        #expect(BookHTTPTransferStore(storage: storage.profileStorageLocations, audioRoot: storage.audiobooksDirectory)
            .transfer(for: transfer.bookID)?.outcome == .active)
        manager.urlSession(nativeSession, downloadTask: native, didResumeAtOffset: 2048, expectedTotalBytes: 8192)

        try await waitUntil { manager.lastErrorByBookId[transfer.bookID] != nil }
        #expect(manager.lastErrorByBookId[transfer.bookID] == BookHTTPTransferStore.Failure.stalled.message)
        #expect(manager.activeBookIds.isEmpty)
        let failed = BookHTTPTransferStore(storage: storage.profileStorageLocations, audioRoot: storage.audiobooksDirectory).transfer(for: transfer.bookID)
        #expect(failed?.outcome == .failed && failed?.failure == .stalled)
        #expect(!FileManager.default.fileExists(atPath: try store.directory(for: transfer).staging.path))
        try await waitUntil { native.state == .completed }

        await manager.startDownload(bookId: transfer.bookID, request: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/retried.mp3")!))
        #expect(manager.lastErrorByBookId[transfer.bookID] == nil)
        try await waitUntil { manager.completedBookIds.contains(transfer.bookID) }
        #expect(storage.isAudiobookDownloaded(transfer.bookID))
        await manager.retire()
        await fixture.close()
    }

    @Test func aServerSilentForTheLimitFailsEveryPartButAQueuedPartBehindProgressDoesNot() async throws {
        let fixture = try DownloadLifecycleFixture()
        let storage = fixture.session.localStorage
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        let nativeSession = URLSession(configuration: .ephemeral)
        defer { nativeSession.invalidateAndCancel(); server.stop() }
        let store = BookHTTPTransferStore(storage: storage.profileStorageLocations, audioRoot: storage.audiobooksDirectory)
        let transfer = try store.begin(bookID: "silent-book", destination: storage.bookAudioDirectory(for: "silent-book"), mode: .multiTrack, count: 2)
        let parts = (0..<2).map { index in
            let task = nativeSession.downloadTask(with: URL(string: "http://127.0.0.1:\(port)/hold-part-\(index).mp3")!)
            task.taskDescription = transfer.taskDescription(for: index)
            return task
        }
        let clock = StallTestClock()
        let manager = BookDownloadManager(storage: storage, activity: ProfileDownloadActivity(),
            stallMonitor: DownloadStallMonitor(now: clock.nowProvider), clientCertificate: { _ in nil })
        manager.stallMonitor.setForeground(true)
        manager.transferInventoryOverride = { [parts] in parts as [URLSessionTask] }
        await manager.restoreTransfers()

        // Only the first part receives bytes; the second waits behind it on the same server.
        for step in 1...5 {
            clock.advance(seconds: 100)
            manager.urlSession(nativeSession, downloadTask: parts[0], didWriteData: 1024, totalBytesWritten: Int64(step * 1024), totalBytesExpectedToWrite: 65_536)
            manager.stallMonitor.evaluate()
        }
        clock.advance(seconds: 119)
        manager.stallMonitor.evaluate()
        try await Task.sleep(for: .milliseconds(200))
        #expect(manager.lastErrorByBookId[transfer.bookID] == nil)
        #expect(manager.activeBookIds == [transfer.bookID])

        clock.advance(seconds: 1)
        manager.stallMonitor.evaluate()
        try await waitUntil { manager.lastErrorByBookId[transfer.bookID] != nil }
        #expect(manager.lastErrorByBookId[transfer.bookID] == BookHTTPTransferStore.Failure.stalled.message)
        try await waitUntil { parts.allSatisfy { $0.state == .completed } }
        await manager.retire()
        await fixture.close()
    }

    @Test func aStalledEpisodeFailsClearlyAndRetryDownloadsIt() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let episode = try await restoredStuckEpisode(port: port, server: server)
        defer { episode.session.invalidateAndCancel() }
        let (fixture, book, session, stuck) = (episode.fixture, episode.book, episode.session, episode.task)
        let downloads = fixture.session.downloads

        downloads.urlSession(session, downloadTask: stuck, didWriteData: 4096, totalBytesWritten: 4096, totalBytesExpectedToWrite: 131_072)
        for _ in 0..<4 { downloads.urlSession(session, downloadTask: stuck, didResumeAtOffset: 4096, expectedTotalBytes: 131_072) }
        try await waitUntil { downloads.tasks.first?.status == .failed }
        #expect(downloads.tasks.first?.errorMessage == BookHTTPTransferStore.Failure.stalled.message)
        #expect(!downloads.hasLiveTransfer(forBookKey: book.downloadKey))
        try await waitUntil { stuck.state == .completed }

        await downloads.retry(taskId: episode.entry.id, book: book)
        #expect(downloads.tasks.map(\.id) == [episode.entry.id])
        #expect(downloads.tasks.first?.status == .completed)
        #expect(fixture.session.localStorage.localAudiobookFilesIfExists(for: book)?.count == 1)
        await fixture.close()
    }

    @Test func aPausedEpisodeIsNeverFailedByLateRestarts() async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let episode = try await restoredStuckEpisode(port: port, server: server)
        defer { episode.session.invalidateAndCancel() }
        let downloads = episode.fixture.session.downloads

        downloads.pause(taskId: episode.entry.id)
        for _ in 0..<5 { downloads.urlSession(episode.session, downloadTask: episode.task, didResumeAtOffset: 0, expectedTotalBytes: 131_072) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(downloads.tasks.first?.status == .paused)
        #expect(downloads.tasks.first?.errorMessage == nil)
        await episode.fixture.close()
    }

    private struct StuckEpisode {
        let fixture: DownloadLifecycleFixture
        let book: Book
        let entry: BookDownloadTask
        let session: URLSession
        let task: URLSessionDownloadTask
    }

    /// A downloading queue entry whose restored attempt is held by the server without sending a byte.
    private func restoredStuckEpisode(port: UInt16, server: DownloadFixtureServer) async throws -> StuckEpisode {
        let book = Book(id: "stall-episode", title: "Stall fixture", partKey: "http://127.0.0.1:\(port)/stall-episode.mp3",
            duration: 60, source: .local, isPodcastEpisode: true)
        var entry = BookDownloadTask.create(bookId: book.downloadKey, title: book.title, source: book.source)
        entry.status = .downloading
        let fixture = try DownloadLifecycleFixture(queue: [entry])
        let session = URLSession(configuration: .ephemeral)
        let stuck = session.downloadTask(with: URL(string: "http://127.0.0.1:\(port)/hold-stuck.mp3")!)
        stuck.taskDescription = "\(entry.id)|\(book.downloadKey)|stuck-attempt"
        stuck.resume()
        try await waitUntil { server.heldCount == 1 }
        fixture.session.downloads.transferInventoryOverride = { [stuck] in [stuck] }
        await fixture.session.downloads.reconcileRestoredTransfers()
        #expect(fixture.session.downloads.hasLiveTransfer(forBookKey: book.downloadKey))
        return StuckEpisode(fixture: fixture, book: book, entry: entry, session: session, task: stuck)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

nonisolated final class StallTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var now: ContinuousClock.Instant { lock.withLock { instant } }
    var nowProvider: @Sendable () -> ContinuousClock.Instant { { self.now } }

    func advance(seconds: Int) {
        lock.withLock { instant = instant.advanced(by: .seconds(seconds)) }
    }
}

nonisolated final class StallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DownloadStall] = []

    var stalls: [DownloadStall] { lock.withLock { values } }

    func record(_ stall: DownloadStall) {
        lock.withLock { values.append(stall) }
    }
}
