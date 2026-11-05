import Foundation
import Network
import Testing
import UIKit

@testable import enve

@MainActor
final class DownloadMetadataGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

final class DownloadLifecycleProvider: PlexProvider, @unchecked Sendable {
    let gate: DownloadMetadataGate?
    let urls: [String]
    init(connection: ServerConnection, gate: DownloadMetadataGate? = nil, urls: [String]) {
        self.gate = gate; self.urls = urls
        super.init(connection: connection)
    }
    override func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        await gate?.wait()
        return PlaybackSessionInfo(sessionId: "download-fixture", audioTracks: urls.enumerated().map {
            AudioTrackInfo(index: $0.offset, startOffset: Double($0.offset * 30), duration: 30,
                contentUrl: $0.element, mimeType: "audio/mpeg")
        }, chapters: [])
    }
}

@MainActor
@Suite(.serialized)
struct DownloadLifecycleTests {
    @Test(arguments: [false, true])
    func backgroundCompletionSurvivesProfileRetirement(retireBeforeCallback: Bool) async throws {
        let fixture = try DownloadLifecycleFixture()
        let storage = fixture.session.localStorage
        let manager = BookDownloadManager(storage: storage, activity: ProfileDownloadActivity(), clientCertificate: { _ in nil })
        let identifier = BookDownloadManager.backgroundSessionIdentifier(for: storage.profileStorageLocations.profileID)
        let native = URLSession(configuration: .background(withIdentifier: identifier), delegate: manager, delegateQueue: nil)
        var completed = false
        CarPlayAppDelegate.storeBackgroundCompletionHandler({ completed = true }, forIdentifier: identifier)
        defer {
            native.invalidateAndCancel()
            CarPlayAppDelegate.consumeBackgroundCompletionHandler(forIdentifier: identifier)?()
        }
        if retireBeforeCallback { await manager.retire() }
        else { manager.onBackgroundEventsFinished = { await manager.retire() } }

        manager.urlSessionDidFinishEvents(forBackgroundURLSession: native)

        try await waitUntil { completed }
        #expect(CarPlayAppDelegate.consumeBackgroundCompletionHandler(forIdentifier: identifier) == nil)
        await fixture.close()
    }

    @Test(arguments: [true, false]) func gatedMetadataCannotScheduleAfterPauseOrCancel(pause: Bool) async throws {
        let fixture = try DownloadLifecycleFixture()
        let gate = DownloadMetadataGate()
        let book = fixture.configure(gate: gate, urls: ["http://127.0.0.1:1/unused.mp3"])
        try await fixture.startNetwork()
        let operation = Task { await fixture.session.downloads.download(book: book) }
        try await waitUntil { gate.entered }
        let id = try #require(fixture.session.downloads.tasks.first?.id)
        if pause { fixture.session.downloads.pause(taskId: id) }
        else { fixture.session.downloads.cancel(taskId: id) }
        gate.release()
        await operation.value
        #expect(fixture.session.downloads.tasks.first?.status == (pause ? .paused : .cancelled))
        #expect(fixture.session.downloadActivity.externalBookIDs.isEmpty)
        #expect(fixture.session.localStorage.localAudiobookFilesIfExists(for: book) == nil)
        await fixture.close()
    }

    @Test(arguments: [true, false]) func activeTransferPauseOrCancelNeverPublishesItsCompletedSubset(pause: Bool) async throws {
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let urls = ["ready", "hold-one", "hold-two"].map { "http://127.0.0.1:\(port)/\($0).mp3" }
        let book = fixture.configure(urls: urls)
        try await fixture.startNetwork()
        let operation = Task { await fixture.session.downloads.download(book: book) }
        try await waitUntil {
            let audioRoot = fixture.session.localStorage.bookAudioDirectory(for: book.downloadKey).deletingLastPathComponent()
            let stages = (try? FileManager.default.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: nil)) ?? []
            return stages.filter { $0.lastPathComponent.hasPrefix(".enve-download-") }.contains {
                ((try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []).contains("chapter_0.mp3")
            }
        }
        #expect(fixture.session.localStorage.localAudiobookFilesIfExists(for: book) == nil)
        let id = try #require(fixture.session.downloads.tasks.first?.id)
        if pause { fixture.session.downloads.pause(taskId: id) }
        else { fixture.session.downloads.cancel(taskId: id) }
        server.release()
        await operation.value
        #expect(fixture.session.downloads.tasks.first?.status == (pause ? .paused : .cancelled))
        #expect(fixture.session.downloadActivity.externalBookIDs.isEmpty)
        #expect(!fixture.session.downloads.completedTasks.contains(where: { $0.bookId == book.downloadKey }))
        #expect(fixture.session.localStorage.localAudiobookFilesIfExists(for: book) == nil)
        let audioRoot = fixture.session.localStorage.bookAudioDirectory(for: book.downloadKey).deletingLastPathComponent()
        #expect((try? FileManager.default.contentsOfDirectory(atPath: audioRoot.path).filter { $0.hasPrefix(".enve-download-") }.isEmpty) == true)
        await fixture.close()
    }

    @Test func cancelledSubsetKeepsPreviousCompleteDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("book")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("previous-complete-book".utf8).write(to: destination.appendingPathComponent("chapter_0.mp3"))
        let attempt = try AtomicDownloadDirectory(destination: destination)
        try Data(repeating: 1, count: 4096).write(to: attempt.staging.appendingPathComponent("chapter_0.mp3"))
        attempt.discard()
        #expect(try Data(contentsOf: destination.appendingPathComponent("chapter_0.mp3")) == Data("previous-complete-book".utf8))
        #expect(!FileManager.default.fileExists(atPath: attempt.staging.path))
    }

    @Test func completedDirectoryReplacesWholePreviousVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("book")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("old.mp3"))
        let attempt = try AtomicDownloadDirectory(destination: destination)
        for index in 0..<3 { try Data(repeating: UInt8(index), count: 4096).write(to: attempt.staging.appendingPathComponent("chapter_\(index).mp3")) }
        try attempt.publish()
        #expect(try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil, options: .skipsHiddenFiles).map(\.lastPathComponent).sorted() == ["chapter_0.mp3", "chapter_1.mp3", "chapter_2.mp3"])
        #expect(!FileManager.default.fileExists(atPath: attempt.staging.path))
    }

    @Test func legacyPartialPlexFilesAreRejectedAndCompleteFilesUseNumericOrder() async throws {
        let fixture = try DownloadLifecycleFixture()
        let providerID = UUID()
        let tracks = (0..<12).reversed().map { AudioTrack(id: "track-\($0)", index: $0, title: "Track \($0)", duration: Double($0 + 10), startOffset: Double($0 * 30), format: "audio/mpeg") }
        let book = Book(id: "legacy-partial", title: "Fixture", audioTracks: tracks, providerId: providerID, source: .plex)
        let directory = fixture.session.localStorage.bookAudioDirectory(for: book.downloadKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 131072).write(to: directory.appendingPathComponent("chapter_0.mp3"))
        #expect(fixture.session.localStorage.localAudiobookFilesIfExists(for: book) == nil)
        for index in 1..<12 { try Data(repeating: UInt8(index), count: 131072).write(to: directory.appendingPathComponent("chapter_\(index).mp3")) }
        let files = try #require(fixture.session.localStorage.localAudiobookFilesIfExists(for: book))
        #expect(files.map(\.lastPathComponent) == (0..<12).map { "chapter_\($0).mp3" })
        let manager = PlaybackManager(profileSession: fixture.session)
        let localTracks = try #require(manager.makeLocalTracks(for: book))
        #expect(localTracks.map(\.duration) == (0..<12).map { Double($0 + 10) })
        #expect(localTracks[1].startOffset == 10)
        #expect(localTracks[2].startOffset == 21)
        await manager.retire()
        await fixture.close()
    }

    @Test(arguments: [Book.BookSource.jellyfin, .emby]) func asynchronousPlanCachesMetadataAndCoverAfterTransfer(source: Book.BookSource) async throws {
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.jpegData(compressionQuality: 0.9)!
        let server = try DownloadFixtureServer(cover: cover)
        let port = try await server.start()
        defer { server.stop() }
        let fixture = try DownloadLifecycleFixture()
        let type: ProviderType = source == .jellyfin ? .jellyfin : .emby
        let connection = ServerConnection(name: "Fixture", url: "http://127.0.0.1:\(port)", type: type,
            token: "fixture-download", isConnected: true)
        fixture.session.providerConnections.connections = [connection]
        let book = Book(id: "hold-audio", ratingKey: "hold-audio", title: "Async fixture", thumb: "http://127.0.0.1:\(port)/cover.jpg",
            duration: 30, source: source, providerId: connection.id)
        try await fixture.startNetwork()
        let operation = Task { await fixture.session.downloads.download(book: book) }
        try await waitUntil { server.heldCount > 0 }
        #expect(fixture.session.downloads.tasks.first?.status == .downloading)
        #expect(!FileManager.default.fileExists(atPath: fixture.session.localStorage.metadataOverridePath(for: book.downloadKey).path))
        server.release()
        await operation.value
        #expect(fixture.session.downloads.tasks.first?.status == .completed)
        let metadata = try fixture.session.localStorage.loadMetadataOverride(OfflineBookMetadata.self, for: book.downloadKey)
        #expect(metadata.title == "Async fixture")
        #expect(FileManager.default.fileExists(atPath: fixture.session.localStorage.coverOverridePath(for: book.downloadKey).path))
        await fixture.close()
    }

    @Test func offlineMetadataUsesCanonicalFallbackDurationsAfterCompletion() async throws {
        let fixture = try DownloadLifecycleFixture()
        let book = Book(id: "ordered-metadata", title: "Metadata fixture", duration: 100, audioTracks: [
            AudioTrack(id: "second", index: 1, title: "Second", duration: 70, startOffset: 30, format: "audio/wav"),
            AudioTrack(id: "first", index: 0, title: "First", duration: 30, startOffset: 0, format: "audio/wav")],
            providerId: UUID(), source: .plex)
        let directory = fixture.session.localStorage.bookAudioDirectory(for: book.downloadKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PlaybackTestAudioFixture.wave(seconds: 30).write(to: directory.appendingPathComponent("chapter_0.wav"))
        try PlaybackTestAudioFixture.wave(seconds: 70).write(to: directory.appendingPathComponent("chapter_1.wav"))
        await fixture.session.downloads.cacheAssetsForOffline(book: book)
        let metadata = try fixture.session.localStorage.loadMetadataOverride(OfflineBookMetadata.self, for: book.downloadKey)
        #expect(metadata.duration == 100)
        #expect(metadata.audioTracks?.map(\.duration) == [30, 70])
        #expect(metadata.audioTracks?.map(\.startOffset) == [0, 30])
        await fixture.close()
    }

    @Test func activeStagingIsExcludedFromDiscoveryAndStorageCleanup() async throws {
        let fixture = try DownloadLifecycleFixture()
        let bookID = "active-book"
        let attempt = try AtomicDownloadDirectory(destination: fixture.session.localStorage.bookAudioDirectory(for: bookID))
        defer { attempt.discard() }
        try Data(repeating: 1, count: 131072).write(to: attempt.staging.appendingPathComponent("chapter_0.mp3"))
        fixture.session.downloadActivity.externalBookIDs.insert(bookID)
        fixture.session.localStorage.invalidateDownloadedIdsCache()
        #expect(!fixture.session.localStorage.downloadedAudiobookIds().contains(attempt.staging.lastPathComponent))
        #expect(!fixture.session.localStorage.getOldestDownloadedBookIds().contains(where: { $0.bookId == attempt.staging.lastPathComponent }))
        var prefs = fixture.session.preferences.loadPreferences()
        prefs.storageLimitEnabled = true
        prefs.storageLimitGB = 0
        fixture.session.preferences.savePreferences(prefs)
        await fixture.session.downloads.checkStorageLimit()
        #expect(FileManager.default.fileExists(atPath: attempt.staging.appendingPathComponent("chapter_0.mp3").path))
        fixture.session.downloadActivity.externalBookIDs.remove(bookID)
        await fixture.close()
    }

    @Test func relaunchAfterAKilledMultiTrackDownloadDiscardsItsStagingAndStopsShowingProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "download-relaunch-\(UUID().uuidString)"
        let id = UUID().uuidString
        let storage = ProfileStorageLocations(profileID: id, documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("Support"), cachesDirectory: root.appendingPathComponent("Caches"))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if let domain = storage.preferencesDomain { UserDefaults.standard.removePersistentDomain(forName: domain) }
            try? FileManager.default.removeItem(at: root)
        }
        var killed = BookDownloadTask.create(bookId: "killed-book", title: "Killed mid-download", source: .plex)
        killed.status = .downloading
        killed.progress = 0.5
        try UnifiedDownloadQueueStore(storage: storage).save([killed])
        let staging = storage.applicationSupportDirectory
            .appendingPathComponent("Enve/Audiobooks/.enve-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: staging.appendingPathComponent("chapter_0.mp3"))

        let session = try ProfileSession(profile: FamilyProfile(id: id, name: "Relaunch fixture", role: .child),
            storage: storage, defaults: UserDefaults(suiteName: suite))
        #expect(staging.deletingLastPathComponent().standardizedFileURL == session.localStorage.audiobooksDirectory.standardizedFileURL)
        #expect(session.downloads.tasks.map(\.status) == [.downloading])
        session.downloads.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline,
            FileManager.default.fileExists(atPath: staging.path) || session.downloads.tasks.contains(where: \.isActive) {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(!FileManager.default.fileExists(atPath: staging.path))
        let task = try #require(session.downloads.tasks.first)
        #expect(!task.isActive)
        #expect(task.progress == 0)
        #expect(!session.localStorage.isAudiobookDownloaded("killed-book"))
        await session.retire()
    }

    @Test(arguments: [BookDownloadTask.DownloadStatus.downloading, .paused])
    func relaunchPublishesDurableAudioBeforeAcknowledgingItsTransfer(status: BookDownloadTask.DownloadStatus) async throws {
        let book = Book(id: UUID().uuidString, title: "Recovered download", duration: 16, source: .plex)
        var task = BookDownloadTask.create(bookId: book.downloadKey, title: book.title, source: book.source)
        task.status = status
        let fixture = try DownloadLifecycleFixture(queue: [task])
        let locations = fixture.session.localStorage.profileStorageLocations
        let root = fixture.session.localStorage.audiobooksDirectory
        await fixture.session.bookStore.upsertBooks([book])
        await fixture.session.retire()
        try UnifiedDownloadQueueStore(storage: locations).save([task])
        let store = BookHTTPTransferStore(storage: locations, audioRoot: root)
        let transfer = try store.begin(bookID: book.downloadKey, destination: fixture.session.localStorage.bookAudioDirectory(for: book.downloadKey), mode: .multiTrack, count: 2)
        let directory = try store.directory(for: transfer)
        for index in 0..<2 {
            let name = "chapter_\(index).wav"
            try PlaybackTestAudioFixture.wave(seconds: 8).write(to: directory.staging.appendingPathComponent(name))
            _ = try store.completePart(bookID: book.downloadKey, attemptID: transfer.attemptID, index: index, fileNames: [name])
        }
        let restored = try ProfileSession(profile: fixture.session.profile, storage: locations, defaults: UserDefaults(suiteName: fixture.suite))
        restored.downloads.start()
        try await waitUntil { restored.downloads.tasks.first?.status == .completed }
        let metadata = try restored.localStorage.loadMetadataOverride(OfflineBookMetadata.self, for: book.downloadKey)
        #expect(metadata.title == book.title)
        #expect(restored.localStorage.localAudiobookFilesIfExists(for: book)?.count == 2)
        #expect(BookHTTPTransferStore(storage: locations, audioRoot: root).all.isEmpty)
        await restored.retire()
        await fixture.close()
    }

    @Test(arguments: [false, true])
    func audiobookshelfStoredBooksDownloadEveryFileWithoutExpandingPodcastEpisodes(podcast: Bool) async throws {
        let fixture = try DownloadLifecycleFixture()
        let item = Data(#"{"id":"abs-files","libraryId":"fixture-library","media":{"audioFiles":[{"ino":"hold-first"},{"ino":"hold-second"}]}}"#.utf8)
        let server = try DownloadFixtureServer(audio: PlaybackTestAudioFixture.wave(seconds: 8), libraryItem: item)
        let port = try await server.start()
        defer { server.stop() }
        let connection = ServerConnection(name: "ABS download fixture", url: "http://127.0.0.1:\(port)", type: .audiobookshelf, token: "fixture-download", isConnected: true)
        fixture.session.providerConnections.connections = [connection]
        let book = Book(id: "abs-files", title: "ABS background fixture", audioFileIno: "hold-first", audioFileInos: podcast ? nil : ["hold-first", "hold-second"], isPodcastEpisode: podcast, providerId: connection.id, source: .audiobookshelf)
        await fixture.session.bookStore.upsertBooks([book])
        let stored = try #require(await fixture.session.bookStore.book(stableId: book.stableId))
        try await fixture.startNetwork()
        let operation = Task { await fixture.session.downloads.download(book: stored) }
        try await waitUntil { server.heldCount > 0 }
        let storage = fixture.session.localStorage
        let store = BookHTTPTransferStore(storage: storage.profileStorageLocations, audioRoot: storage.audiobooksDirectory)
        let transfer = try #require(store.transfer(for: book.downloadKey))
        #expect(transfer.parts.count == (podcast ? 1 : 2))
        #expect(transfer.parts.allSatisfy { $0.fileNames.isEmpty })
        #expect(transfer.outcome == .active)
        #expect(storage.localAudiobookFilesIfExists(for: book) == nil)
        server.release()
        await operation.value
        #expect(fixture.session.downloads.tasks.first?.status == .completed)
        #expect(storage.localAudiobookFilesIfExists(for: book)?.count == (podcast ? 1 : 2))
        #expect(BookHTTPTransferStore(storage: storage.profileStorageLocations, audioRoot: storage.audiobooksDirectory).all.isEmpty)
        await fixture.close()
    }

    @Test func restorationResumesOwnedSuspendedTasksAndRetainsCompletedParts() async throws {
        let fixture = try DownloadLifecycleFixture()
        let storage = fixture.session.localStorage
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        let nativeSession = URLSession(configuration: .ephemeral)
        defer { nativeSession.invalidateAndCancel(); server.stop() }
        let store = BookHTTPTransferStore(storage: storage.profileStorageLocations, audioRoot: storage.audiobooksDirectory)
        let transfer = try store.begin(bookID: "suspended-book", destination: storage.bookAudioDirectory(for: "suspended-book"), mode: .multiTrack, count: 2)
        let directory = try store.directory(for: transfer)
        let completedPart = directory.staging.appendingPathComponent("chapter_0.mp3")
        try Data(repeating: 1, count: 131072).write(to: completedPart)
        _ = try store.completePart(bookID: transfer.bookID, attemptID: transfer.attemptID, index: 0, fileNames: [completedPart.lastPathComponent])
        let native = nativeSession.downloadTask(with: URL(string: "http://127.0.0.1:\(port)/hold-restored.mp3")!)
        native.taskDescription = transfer.taskDescription(for: 1)
        let manager = BookDownloadManager(storage: storage, activity: ProfileDownloadActivity(), clientCertificate: { _ in nil })
        manager.transferInventoryOverride = { [native] }
        await manager.restoreTransfers()
        #expect(native.state == .running)
        #expect(manager.activeBookIds == [transfer.bookID])
        #expect(FileManager.default.fileExists(atPath: completedPart.path))
        #expect(!storage.isAudiobookDownloaded(transfer.bookID))
        manager.cancelDownload(bookId: transfer.bookID)
        #expect(!FileManager.default.fileExists(atPath: directory.staging.path))
        #expect(BookHTTPTransferStore(storage: storage.profileStorageLocations, audioRoot: storage.audiobooksDirectory).all.isEmpty)
        await manager.retire()
        await fixture.close()
    }

    @Test func retirementBeforeReattachmentRevokesPersistedTransfers() async throws {
        let fixture = try DownloadLifecycleFixture()
        let storage = fixture.session.localStorage
        let store = BookHTTPTransferStore(storage: storage.profileStorageLocations, audioRoot: storage.audiobooksDirectory)
        let transfer = try store.begin(bookID: "retired-transfer", destination: storage.bookAudioDirectory(for: "retired-transfer"), mode: .single, count: 1)
        let manager = BookDownloadManager(storage: storage, activity: ProfileDownloadActivity(), clientCertificate: { _ in nil })
        await manager.retire()
        #expect(!FileManager.default.fileExists(atPath: try store.directory(for: transfer).staging.path))
        #expect(BookHTTPTransferStore(storage: storage.profileStorageLocations, audioRoot: storage.audiobooksDirectory).all.isEmpty)
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

@MainActor
final class DownloadLifecycleFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "download-lifecycle-\(UUID().uuidString)"
    let session: ProfileSession
    init(queue: [BookDownloadTask] = []) throws {
        let id = UUID().uuidString
        let storage = ProfileStorageLocations(profileID: id, documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("Support"), cachesDirectory: root.appendingPathComponent("Caches"))
        if !queue.isEmpty { try UnifiedDownloadQueueStore(storage: storage).save(queue) }
        session = try ProfileSession(profile: FamilyProfile(id: id, name: "Download fixture", role: .child), storage: storage,
            defaults: UserDefaults(suiteName: suite))
    }
    func configure(gate: DownloadMetadataGate? = nil, urls: [String]) -> Book {
        let connection = ServerConnection(name: "Fixture", url: "http://127.0.0.1", type: .plex)
        session.providerConnections.connections = [connection]
        session.providerConnections[connection.id] = DownloadLifecycleProvider(connection: connection, gate: gate, urls: urls)
        return Book(id: "fixture", title: "Download fixture", duration: Double(urls.count * 30),
            audioTracks: urls.enumerated().map { AudioTrack(id: "\($0.offset)", index: $0.offset, title: "Track", duration: 30, startOffset: Double($0.offset * 30)) },
            providerId: connection.id, source: .plex)
    }
    func startNetwork() async throws {
        session.downloads.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while session.downloads.networkMonitorCurrentPath.status != .satisfied {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func close() async {
        await session.retire()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

// Loopback-only disposable HTTP fixture: `hold-` tracks stay in flight until released, `missing-` tracks return 404,
// and `range-` sends half of `rangePayload` with validators, holds, and answers a Range request with the rest.
nonisolated final class DownloadFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DownloadFixtureServer")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var held: [NWConnection] = []
    private var released = false
    private var received: [ObjectIdentifier: Data] = [:]
    private let cover: Data?
    private let audio: Data?
    private let libraryItem: Data?
    private var audioByteCount = 0
    var audioBytesServed: Int { lock.lock(); defer { lock.unlock() }; return audioByteCount }
    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    static let rangePayload = Data((0..<262_144).map { UInt8(truncatingIfNeeded: $0 % 251) })
    static let rangeSplit = 131_072
    private var rangeLog: [String] = []
    var rangeRequests: [String] { lock.lock(); defer { lock.unlock() }; return rangeLog }
    init(cover: Data? = nil, audio: Data? = nil, libraryItem: Data? = nil) throws {
        self.audio = audio
        self.cover = cover
        self.libraryItem = libraryItem
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                lock.lock(); connections.append(connection); lock.unlock()
                connection.start(queue: queue)
                receive(connection)
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            guard let data, error == nil else { return }
            lock.lock()
            let key = ObjectIdentifier(connection)
            received[key, default: Data()].append(data)
            let request = String(decoding: received[key]!, as: UTF8.self)
            let ready = request.contains("\r\n\r\n")
            if ready { received.removeValue(forKey: key) }
            lock.unlock()
            if !ready { if !complete { receive(connection) }; return }
            let line = request.split(separator: "\n").first ?? ""
            if let libraryItem, line.split(separator: " ").dropFirst().first?.split(separator: "?").first == "/api/items/abs-files" {
                var data = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(libraryItem.count)\r\nConnection: close\r\n\r\n".utf8)
                data.append(libraryItem)
                connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            } else if line.contains("hold-") {
                lock.lock()
                let respondNow = released
                if !respondNow { held.append(connection) }
                lock.unlock()
                if respondNow { respond(connection) }
            } else if line.contains("/audio.wav"), let audio {
                serveAudio(connection, request: request, payload: audio)
            } else if line.contains("range-") {
                serveRange(connection, request: request)
            } else if line.contains("missing-") {
                let data = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            } else { respond(connection, isCover: line.contains("/cover.jpg")) }
        }
    }
    private func respond(_ connection: NWConnection, isCover: Bool = false) {
        let payload = isCover ? (cover ?? Data()) : (audio ?? Data(repeating: 65, count: 131072))
        let type = isCover ? "image/jpeg" : (audio == nil ? "audio/mpeg" : "audio/wav")
        var data = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(payload)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }
    private func serveAudio(_ connection: NWConnection, request: String, payload: Data) {
        guard request.lowercased().contains("authorization: bearer fixture") else {
            connection.send(content: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let range = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
        let bounds = range?.components(separatedBy: "=").last?.components(separatedBy: "-")
        let start = bounds?.first.flatMap(Int.init) ?? 0
        let end = min(bounds?.last.flatMap(Int.init) ?? payload.count - 1, payload.count - 1)
        lock.lock(); rangeLog.append(range ?? "none"); lock.unlock()
        guard start >= 0, start <= end else { connection.cancel(); return }
        let count = end - start + 1
        lock.lock(); audioByteCount += count; lock.unlock()
        var header = "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: audio/wav\r\nAccept-Ranges: bytes\r\nContent-Length: \(count)\r\nConnection: close\r\n"
        if range != nil { header += "Content-Range: bytes \(start)-\(end)/\(payload.count)\r\n" }
        var response = Data((header + "\r\n").utf8)
        if !request.hasPrefix("HEAD ") { response.append(payload[start...end]) }
        connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }
    private func serveRange(_ connection: NWConnection, request: String) {
        let payload = Self.rangePayload
        let validators = "Accept-Ranges: bytes\r\nETag: \"enve-range-fixture\"\r\nLast-Modified: Wed, 21 Oct 2026 07:28:00 GMT\r\nContent-Type: audio/mpeg\r\n"
        let rangeLine = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("range:") }
        let start = rangeLine.flatMap { line in
            line.split(separator: "=").last?.split(separator: "-").first.flatMap { Int($0) }
        }
        lock.lock(); rangeLog.append(rangeLine.map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) } ?? "none"); lock.unlock()
        if let start, start > 0, start < payload.count {
            var data = Data("HTTP/1.1 206 Partial Content\r\n\(validators)Content-Range: bytes \(start)-\(payload.count - 1)/\(payload.count)\r\nContent-Length: \(payload.count - start)\r\nConnection: close\r\n\r\n".utf8)
            data.append(payload[start...])
            connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        } else {
            var data = Data("HTTP/1.1 200 OK\r\n\(validators)Content-Length: \(payload.count)\r\n\r\n".utf8)
            data.append(payload.prefix(Self.rangeSplit))
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }
    func release() { lock.lock(); released = true; let values = held; held.removeAll(); lock.unlock(); values.forEach { respond($0) } }
    func stop() { listener.cancel(); lock.lock(); let values = connections; connections.removeAll(); lock.unlock(); values.forEach { $0.cancel() } }
}
