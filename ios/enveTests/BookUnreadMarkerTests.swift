import Combine
import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
private final class UnreadSessionStub: CurrentBookSession {
    var currentBook: Book?
}

@MainActor
private final class UnreadConnectionStub: ProviderConnectionAccessing {
    var connections: [ServerConnection] = []

    func backend(id: String) -> BackendConfig? { nil }
    func allBackends() -> [BackendConfig] { [] }
    func provider(for providerId: UUID) -> LibraryProvider? { nil }
    func provider(for book: Book) -> LibraryProvider? { nil }
}

@MainActor
private final class UnreadNoopWriter: BookWriting {
    func upsertBooks(_ books: [Book]) async {}
    func replaceLibrary(books: [Book], libraryId: String, providerId: UUID, allowSparseResult: Bool) async {}
    func deleteBooksFromUnknownProviders(validProviderIds: Set<String>) async -> Int { 0 }
    func deleteBooksFromInactiveLibraries(
        validProviderIds: Set<String>,
        restrictedLibraryIds: [String: Set<String>]
    ) async -> Int { 0 }
    func updateEbookFileURL(uniqueId: String, url: URL?) async {}
    func setHidden(_ hidden: Bool, stableId: String) async {}
    func setDeleted(_ deleted: Bool, stableId: String) async {}
    func deleteBooks(uniqueIds: Set<String>) async {}
    func importLegacyBooks(_ books: [Book], hiddenStableIds: Set<String>, deletedStableIds: Set<String>) async {}
    func clearAllData() async {}
}

@MainActor
private final class UnreadPlaybackStub: PlaybackControlling {
    private let subject = CurrentValueSubject<PlaybackSnapshot, Never>(.idle)
    var events: [String] = []

    let ownsProgressPersistence = false
    var snapshot: PlaybackSnapshot { subject.value }
    var snapshots: AnyPublisher<PlaybackSnapshot, Never> { subject.eraseToAnyPublisher() }

    func load(_ book: Book, position: TimeInterval) {
        subject.send(
            PlaybackSnapshot(
                currentBook: book, isPlaying: true, position: position, duration: book.duration ?? 0,
                playbackSpeed: 1, volume: 1, isLoaded: true, isLoading: false,
                isOverlayPlaybackActive: false, errorDescription: nil
            )
        )
    }

    func stop() {
        events.append("stop")
        subject.send(.idle)
    }

    func seek(to time: TimeInterval) { events.append("seek") }
    func play() {}
    func pause() {}
    func togglePlay() {}
    func skipForward(seconds: TimeInterval) {}
    func skipBackward(seconds: TimeInterval) {}
    func setPlaybackRate(_ rate: Double) {}
    func setVolume(_ volume: Double) {}
    func fadeOutAndPause(duration: TimeInterval, steps: Int) async {}
}

@MainActor
private final class UnreadFixture {
    let suiteName = "BookUnreadMarkerTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let lastOpened: LastOpenedBookStore
    let playerState: PlayerStateStore
    let session = UnreadSessionStub()
    let playback = UnreadPlaybackStub()
    var forgotten: [String] = []
    var resets: [String] = []
    var pairs: [String: String] = [:]

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        lastOpened = LastOpenedBookStore(defaults: defaults)
        playerState = PlayerStateStore(defaults: defaults)
    }

    func marker(reset: ((Book) -> Void)? = nil) -> BookUnreadMarker {
        BookUnreadMarker(
            lastOpened: lastOpened,
            playerState: playerState,
            session: session,
            playback: playback,
            forgetRestoredBook: { [unowned self] in forgotten.append($0) },
            pairedStableId: { [unowned self] in pairs[$0.stableId] },
            resetProgress: { [unowned self] book in
                playback.events.append("reset")
                resets.append(book.stableId)
                reset?(book)
            }
        )
    }

    func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
@Suite(.serialized)
struct BookUnreadMarkerTests {
    @Test func confirmationThresholdIsTwoMinutesOrOnePercent() {
        #expect(!BookUnreadMarker.isMeaningful(listenedSeconds: 0, readFraction: 0, isFinished: false))
        #expect(!BookUnreadMarker.isMeaningful(listenedSeconds: 120, readFraction: 0, isFinished: false))
        #expect(BookUnreadMarker.isMeaningful(listenedSeconds: 121, readFraction: 0, isFinished: false))
        #expect(!BookUnreadMarker.isMeaningful(listenedSeconds: 0, readFraction: 0.01, isFinished: false))
        #expect(BookUnreadMarker.isMeaningful(listenedSeconds: 0, readFraction: 0.011, isFinished: false))
        #expect(BookUnreadMarker.isMeaningful(listenedSeconds: 0, readFraction: 0, isFinished: true))
    }

    @Test func confirmationUsesLivePlaybackPositionForTheLoadedBook() {
        let fixture = UnreadFixture()
        defer { fixture.tearDown() }
        let book = makeAudiobook("live", currentTime: 30)
        let marker = fixture.marker()

        #expect(!marker.needsConfirmation(book))
        fixture.playback.load(book, position: 300)
        #expect(marker.needsConfirmation(book))
        #expect(marker.needsConfirmation(makeEbook("read", progress: 0.4)))
        #expect(!marker.needsConfirmation(makeEbook("glance", progress: 0.005)))
    }

    @Test func markingTheCurrentBookStopsPlaybackBeforeResetAndClearsTheMantel() async {
        let fixture = UnreadFixture()
        defer { fixture.tearDown() }
        let book = makeAudiobook("current", currentTime: 400)
        fixture.lastOpened.record(book)
        fixture.session.currentBook = book
        fixture.playerState.saveLastPlayedBookId(book.stableId)
        fixture.playback.load(book, position: 400)

        await fixture.marker().markUnread(book)

        #expect(fixture.playback.events == ["stop", "reset"])
        #expect(fixture.session.currentBook == nil)
        #expect(fixture.lastOpened.stableId == nil)
        #expect(LastOpenedBookStore(defaults: fixture.defaults).stableId == nil)
        #expect(fixture.playerState.loadLastPlayedBookId() == nil)
        #expect(fixture.forgotten == [book.stableId])
        #expect(fixture.resets == [book.stableId])
    }

    @Test func markingAnotherBookLeavesTheCurrentBookAlone() async {
        let fixture = UnreadFixture()
        defer { fixture.tearDown() }
        let current = makeAudiobook("current", currentTime: 400)
        let other = makeAudiobook("other", currentTime: 50)
        fixture.lastOpened.record(current)
        fixture.session.currentBook = current
        fixture.playerState.saveLastPlayedBookId(current.stableId)
        fixture.playback.load(current, position: 400)

        await fixture.marker().markUnread(other)

        #expect(fixture.playback.events == ["reset"])
        #expect(fixture.playback.snapshot.currentBook?.stableId == current.stableId)
        #expect(fixture.session.currentBook?.stableId == current.stableId)
        #expect(fixture.lastOpened.stableId == current.stableId)
        #expect(fixture.playerState.loadLastPlayedBookId() == current.stableId)
        #expect(fixture.resets == [other.stableId])
    }

    @Test func markingAnEbookUnreadStopsItsPlayingLinkedAudiobookBeforeReset() async {
        let fixture = UnreadFixture()
        defer { fixture.tearDown() }
        let audiobook = makeAudiobook("linked-audio", currentTime: 900)
        let ebook = makeEbook("linked-ebook", progress: 0.3)
        fixture.pairs[ebook.stableId] = audiobook.stableId
        fixture.playback.load(audiobook, position: 900)

        await fixture.marker().markUnread(ebook)

        #expect(fixture.playback.events == ["stop", "reset"])
        #expect(fixture.resets == [ebook.stableId])
    }

    @Test func linkedPairResolvesTheCounterpartInBothDirections() async throws {
        let fixture = UnreadFixture()
        defer { fixture.tearDown() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = FamilyProfile(id: UUID().uuidString, name: "Unread pair", role: .adult)
        let storage = ProfileStorageLocations(profileID: profile.id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"))
        defer { storage.preferencesDomain.map(UserDefaults.standard.removePersistentDomain(forName:)) }
        let session = try ProfileSession(profile: profile, storage: storage, defaults: fixture.defaults)
        let audiobook = makeAudiobook("pair-audio", currentTime: 900)
        var ebook = makeEbook("pair-ebook", progress: 0.3)
        ebook.linkedAudiobookStableId = audiobook.stableId
        await session.bookStore.upsertBooks([audiobook, ebook])
        await session.bookStore.upsertLink(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId, chapterOffset: 0)

        #expect(await session.linkedProgress.pairedStableId(for: ebook) == audiobook.stableId)
        #expect(await session.linkedProgress.pairedStableId(for: audiobook) == ebook.stableId)
        #expect(await session.linkedProgress.pairedStableId(for: makeEbook("unlinked", progress: 0.1)) == nil)
        await session.retire()
    }

    @Test func markingUnreadResetsProgressButKeepsAnnotationsBookmarksAndDownloads() async throws {
        let fixture = UnreadFixture()
        defer { fixture.tearDown() }
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let configuration = ModelConfiguration(
            "BookUnreadMarkerTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let bookStore = SwiftDataBookStore(container: try ModelContainer(for: schema, configurations: [configuration]))
        let progressFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookUnreadMarkerTests-\(UUID().uuidString).json")
        let downloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookUnreadMarkerTests-\(UUID().uuidString).epub")
        try Data("epub".utf8).write(to: downloadURL)
        defer {
            try? FileManager.default.removeItem(at: progressFileURL)
            try? FileManager.default.removeItem(at: downloadURL)
        }

        var book = makeEbook("downloaded", progress: 0.42)
        book.ebookFileURL = downloadURL
        let library = LibraryBookCache(writer: UnreadNoopWriter())
        library.books = [book]
        let artifacts = ReaderArtifactsStore(defaults: fixture.defaults)
        artifacts.saveAnnotations(bookId: book.stableId, annotations: [ReaderAnnotation(bookId: book.stableId, text: "kept")])
        artifacts.saveBookmarks(bookId: book.stableId, bookmarks: [Bookmark(bookId: book.stableId, position: 12, title: "kept")])

        let progress = UserProgressStore(
            library: library,
            session: fixture.session,
            bookStore: bookStore,
            providerConnections: UnreadConnectionStub(),
            progressFileURL: progressFileURL,
            progressCache: BookProgressStore(defaults: fixture.defaults),
            defaults: fixture.defaults,
            playbackState: { [playback = fixture.playback] in playback }
        )
        progress.syncProgressToServer = false
        fixture.lastOpened.record(book)

        await fixture.marker { progress.resetToBeginning(for: $0) }.markUnread(book)

        let reset = try #require(library.books.first)
        #expect(reset.canonicalEbookProgress == 0)
        #expect(reset.epubLocator == nil)
        #expect(reset.ebookFileURL == downloadURL)
        #expect(FileManager.default.fileExists(atPath: downloadURL.path))
        #expect(artifacts.loadAnnotations(bookId: book.stableId).map(\.text) == ["kept"])
        #expect(artifacts.loadBookmarks(bookId: book.stableId).map(\.title) == ["kept"])
        #expect(fixture.lastOpened.stableId == nil)
    }

    @Test func markingUnreadPersistsForBooksOutsideTheInMemoryLibrary() async throws {
        let fixture = UnreadFixture()
        defer { fixture.tearDown() }
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let configuration = ModelConfiguration(
            "BookUnreadMarkerTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let bookStore = SwiftDataBookStore(container: try ModelContainer(for: schema, configurations: [configuration]))
        let progressFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookUnreadMarkerTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: progressFileURL) }

        let book = makeEbook("paged", progress: 0.2)
        await bookStore.upsertBooks([book])
        #expect(await bookStore.continueReadingBooks(limit: 10).map(\.stableId) == [book.stableId])

        let progress = UserProgressStore(
            library: LibraryBookCache(writer: UnreadNoopWriter()),
            session: fixture.session,
            bookStore: bookStore,
            providerConnections: UnreadConnectionStub(),
            progressFileURL: progressFileURL,
            progressCache: BookProgressStore(defaults: fixture.defaults),
            defaults: fixture.defaults,
            playbackState: { [playback = fixture.playback] in playback }
        )
        progress.syncProgressToServer = false

        await fixture.marker { progress.resetToBeginning(for: $0) }.markUnread(book)

        let deadline = ContinuousClock.now + .seconds(5)
        while await bookStore.continueReadingBooks(limit: 10).isEmpty == false {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await bookStore.continueReadingBooks(limit: 10).isEmpty)
        #expect(await bookStore.book(uniqueId: book.uniqueId)?.canonicalEbookProgress == 0)
    }
}

private let unreadProviderId = UUID(uuidString: "4C6F0E1A-2B3D-4E5F-8A9B-0C1D2E3F4A5B")!

private func makeAudiobook(_ id: String, currentTime: TimeInterval) -> Book {
    Book(
        id: id, title: "Audiobook \(id)", duration: 3_600, source: .audiobookshelf, mediaType: .audiobook,
        currentTime: currentTime, lastUpdate: Date(timeIntervalSince1970: 100),
        providerId: unreadProviderId, libraryId: "library"
    )
}

private func makeEbook(_ id: String, progress: Double) -> Book {
    Book(
        id: id, title: "Ebook \(id)", source: .audiobookshelf, mediaType: .ebook, ebookProgress: progress,
        lastUpdate: Date(timeIntervalSince1970: 100), providerId: unreadProviderId, libraryId: "library"
    )
}
