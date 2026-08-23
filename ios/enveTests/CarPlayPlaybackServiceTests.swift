import Combine
import Foundation
import Testing

@testable import enve

@MainActor
struct CarPlayChapterResolutionTests {
    @Test func bookChaptersWinAndAreSortedByStart() {
        let fixture = Fixture()
        fixture.library.books = [book("one", chapters: [chapter("cached", start: 0)])]
        fixture.chapters.playerBook = book("one")
        fixture.chapters.playerChapters = [chapter("player", start: 0)]
        fixture.chapters.cached = ["local:unknown:one": [chapter("artifact", start: 0)]]

        let resolved = fixture.service.chapters(
            for: book("one", chapters: [chapter("late", start: 90), chapter("early", start: 10)])
        )

        #expect(resolved.map(\.id) == ["early", "late"])
    }

    @Test func inMemoryChaptersAreUsedWhenTheBookCarriesNone() {
        let fixture = Fixture()
        fixture.library.books = [book("one", chapters: [chapter("b", start: 60), chapter("a", start: 5)])]
        fixture.chapters.playerBook = book("one")
        fixture.chapters.playerChapters = [chapter("player", start: 0)]

        #expect(fixture.service.chapters(for: book("one")).map(\.id) == ["a", "b"])
    }

    @Test func playerChaptersAreUsedOnlyForAMatchingBook() {
        let fixture = Fixture()
        fixture.chapters.playerBook = book("other")
        fixture.chapters.playerChapters = [chapter("player", start: 0)]

        #expect(fixture.service.chapters(for: book("one")).isEmpty)

        fixture.chapters.playerBook = book("one")
        #expect(fixture.service.chapters(for: book("one")).map(\.id) == ["player"])
    }

    @Test func cachedChaptersFallBackFromStableIdToBookId() {
        let fixture = Fixture()
        fixture.chapters.cached = ["one": [chapter("byBookId", start: 0)]]

        #expect(fixture.service.chapters(for: book("one")).map(\.id) == ["byBookId"])

        fixture.chapters.cached["local:unknown:one"] = [chapter("byStableId", start: 0)]
        #expect(fixture.service.chapters(for: book("one")).map(\.id) == ["byStableId"])
    }

    @Test func emptySourcesResolveToNoChapters() {
        #expect(Fixture().service.chapters(for: book("one")).isEmpty)
    }
}

@MainActor
struct CarPlayCurrentBookTests {
    @Test func currentBookMatchesOnUniqueId() {
        let fixture = Fixture()
        let provider = UUID()
        fixture.controller.snapshot = snapshot(currentBook: book("one", providerId: provider))

        #expect(fixture.service.isCurrent(book("one", providerId: provider)))
        #expect(!fixture.service.isCurrent(book("one", providerId: UUID())))
        #expect(!fixture.service.isCurrent(book("two", providerId: provider)))
    }

    @Test func nothingIsCurrentWhenPlaybackIsIdle() {
        #expect(!Fixture().service.isCurrent(book("one")))
    }

    @Test func sameBookMatchingAcceptsAnyIdentity() {
        let left = book("one", providerId: UUID())
        let right = book("one", providerId: UUID())

        #expect(CarPlayPlaybackService.isSameBook(left, right))
        #expect(!CarPlayPlaybackService.isSameBook(left, book("two", providerId: UUID())))
    }
}

@MainActor
struct CarPlayPlaybackRoutingTests {
    @Test func audiobooksStartThroughTheBookStarter() async {
        let fixture = Fixture()
        let target = book("one")
        fixture.controller.snapshot = readySnapshot(for: target)

        #expect(await fixture.service.play(target))
        #expect(fixture.starter.played.map(\.id) == ["one"])
        #expect(fixture.starter.readAloudPlayed.isEmpty)
        #expect(fixture.nowPlaying.refreshCount == 1)
    }

    @Test func readaloudBooksStartThroughAlignedPlaybackWithResolvedChapters() async {
        let fixture = Fixture()
        let target = readaloudBook("one")
        fixture.library.books = [readaloudBook("one", chapters: [chapter("b", start: 60), chapter("a", start: 5)])]
        fixture.controller.snapshot = readySnapshot(for: target)

        #expect(await fixture.service.play(target))
        #expect(fixture.starter.played.isEmpty)
        #expect(fixture.starter.readAloudPlayed.map(\.id) == ["one"])
        #expect(fixture.starter.readAloudPlayed.first?.chapters?.map(\.id) == ["a", "b"])
    }

    @Test func aFailureRaisedSynchronouslyByTheStarterEndsTheStartAttempt() async {
        let fixture = Fixture()
        fixture.controller.snapshot = snapshot(errorDescription: "stale")
        fixture.starter.onPlay = { [controller = fixture.controller] book in
            controller.snapshot = snapshot(currentBook: book, isLoading: true, errorDescription: "network unreachable")
        }

        #expect(await fixture.service.play(book("one")) == false)
        #expect(fixture.nowPlaying.refreshCount == 0)
    }

    @Test func aFailureRaisedAfterTheStarterReturnsEndsTheStartAttempt() async {
        let fixture = Fixture()
        fixture.controller.snapshot = snapshot(errorDescription: "stale")
        fixture.starter.onPlay = { [controller = fixture.controller] book in
            controller.snapshot = snapshot(currentBook: book, isLoading: true)
            controller.change(
                to: snapshot(currentBook: book, isLoading: true, errorDescription: "network unreachable"),
                afterReads: 2
            )
        }

        #expect(await fixture.service.play(book("one")) == false)
        #expect(fixture.nowPlaying.refreshCount == 0)
    }

    @Test func anErrorPresentBeforeTheStartDoesNotAbortIt() async {
        let fixture = Fixture()
        let target = book("one")
        fixture.controller.snapshot = snapshot(errorDescription: "stale")
        fixture.starter.onPlay = { [controller = fixture.controller] book in
            controller.snapshot = readySnapshot(for: book)
        }

        #expect(await fixture.service.play(target))
        #expect(fixture.nowPlaying.refreshCount == 1)
    }

    @Test func aStartThatNeverTakesHoldTimesOut() async {
        let fixture = Fixture(startTimeout: .milliseconds(150))

        #expect(await fixture.service.play(book("one")) == false)
        #expect(fixture.nowPlaying.refreshCount == 0)
    }

    @Test func aPlayerStillLoadingAtTheDeadlineFallsBackToTheCurrentBookMatch() async {
        let fixture = Fixture(startTimeout: .milliseconds(150))
        let target = book("one")
        fixture.starter.onPlay = { [controller = fixture.controller] book in
            controller.snapshot = snapshot(currentBook: book, duration: 600, isLoaded: true, isLoading: true)
        }

        #expect(await fixture.service.play(target))
    }
}

@MainActor
struct CarPlayDownloadDecisionTests {
    @Test func downloadedAudiobooksReportAsDownloaded() {
        let fixture = Fixture()
        fixture.downloads.downloaded = ["local:unknown:one"]

        #expect(fixture.service.isDownloaded(book("one"), downloadedIds: ["local:unknown:one"]))
    }

    @Test func anActiveDownloadIsNotYetDownloaded() {
        let fixture = Fixture()
        fixture.downloads.downloaded = ["local:unknown:one"]
        fixture.downloads.active = ["local:unknown:one"]

        #expect(!fixture.service.isDownloaded(book("one"), downloadedIds: ["local:unknown:one"]))
    }

    @Test func plainEbooksAreNeverDownloadedForCarPlay() {
        let fixture = Fixture()
        fixture.downloads.downloaded = ["local:unknown:one"]

        #expect(!fixture.service.isDownloaded(book("one", mediaType: .ebook), downloadedIds: ["local:unknown:one"]))
    }

    @Test func readaloudEbooksCountWhenTheLocalFileResolves() {
        let fixture = Fixture()
        let target = readaloudBook("one", mediaType: .ebook)

        #expect(!fixture.service.isDownloaded(target, downloadedIds: []))

        fixture.downloads.localReadaloud = ["local:unknown:one"]
        #expect(fixture.service.isDownloaded(target, downloadedIds: []))
    }

    @Test func readaloudDetectionRequiresAMediaOverlay() {
        let fixture = Fixture()

        #expect(fixture.service.isReadaloudPlayable(readaloudBook("one")))
        #expect(!fixture.service.isReadaloudPlayable(book("one")))
    }
}

@MainActor
struct CarPlayCatalogTests {
    @Test func continueListeningPrefersTheMostRecentProgress() {
        let books = [book("stale"), book("fresh"), book("untouched")]
        let lastUpdated = ["local:unknown:stale": 100.0, "local:unknown:fresh": 900.0]

        #expect(
            CarPlayCatalog.continueListeningOrder(books, lastUpdated: lastUpdated).map(\.id)
                == ["fresh", "stale", "untouched"]
        )
    }

    @Test func booksWithoutProgressKeepTheirIncomingOrder() {
        let books = [book("a"), book("b"), book("c")]

        #expect(CarPlayCatalog.continueListeningOrder(books, lastUpdated: [:]).map(\.id) == ["a", "b", "c"])
    }

    @Test func downloadedMatchingSkipsEbooksAndDeduplicates() {
        let candidates = [
            book("one"),
            book("ebook", mediaType: .ebook),
            book("one"),
            book("missing"),
        ]

        let matched = CarPlayCatalog.downloadedAudiobooks(
            candidates,
            downloadedIds: ["one", "ebook"],
            identifier: { $0.id }
        )

        #expect(matched.map(\.id) == ["one"])
    }

    @Test func alphabeticalGroupsBucketNonLettersUnderHash() {
        let books = [book("apple", title: "Apple"), book("digit", title: "42"), book("beta", title: "beta")]

        let groups = CarPlayCatalog.alphabeticalGroups(books, maxSections: 10, maxItems: 10)

        #expect(groups.map(\.letter) == ["A", "B", "#"])
        #expect(groups.map { $0.books.map(\.id) } == [["apple"], ["beta"], ["digit"]])
    }

    @Test func alphabeticalGroupsRespectSectionAndItemCaps() {
        let books = (0..<6).map { book("a\($0)", title: "A\($0)") } + (0..<6).map { book("b\($0)", title: "B\($0)") }

        let capped = CarPlayCatalog.alphabeticalGroups(books, maxSections: 1, maxItems: 4)
        #expect(capped.map(\.letter) == ["A"])
        #expect(capped.first?.books.count == 4)

        let split = CarPlayCatalog.alphabeticalGroups(books, maxSections: 2, maxItems: 4)
        #expect(split.map { $0.books.count } == [2, 2])
    }

    @Test func connectionSignatureIgnoresArchivedConnectionsAndOrdering() {
        let first = UUID()
        let second = UUID()
        let active = [
            connection(first, libraries: ["b", "a"]),
            connection(second, libraries: ["c"]),
        ]
        let reordered = [
            connection(second, libraries: ["c"]),
            connection(first, libraries: ["a", "b"]),
        ]

        #expect(CarPlayCatalog.connectionSignature(active) == CarPlayCatalog.connectionSignature(reordered))
        #expect(
            CarPlayCatalog.connectionSignature(active + [connection(UUID(), libraries: ["x"], isArchived: true)])
                == CarPlayCatalog.connectionSignature(active)
        )
    }
}

@MainActor
private final class Fixture {
    let controller = StubPlaybackController()
    let nowPlaying = StubNowPlayingUpdater()
    let starter = StubBookStarter()
    let library = StubLibrary()
    let chapters = StubChapterSource()
    let downloads = StubDownloadState()
    let service: CarPlayPlaybackService

    init(startTimeout: Duration = .seconds(5)) {
        service = CarPlayPlaybackService(
            controller: controller,
            nowPlayingUpdater: nowPlaying,
            bookStarter: starter,
            library: library,
            chapterSource: chapters,
            downloads: downloads,
            startTimeout: startTimeout,
            startPollInterval: .milliseconds(1)
        )
    }
}

@MainActor
private final class StubPlaybackController: PlaybackControlling {
    private var stored: PlaybackSnapshot = .idle
    private var reads = 0
    private var deferredChange: (afterReads: Int, snapshot: PlaybackSnapshot)?

    var snapshot: PlaybackSnapshot {
        get {
            reads += 1
            if let change = deferredChange, reads > change.afterReads {
                deferredChange = nil
                stored = change.snapshot
                subject.send(stored)
            }
            return stored
        }
        set {
            stored = newValue
            subject.send(newValue)
        }
    }

    private let subject = PassthroughSubject<PlaybackSnapshot, Never>()
    var snapshots: AnyPublisher<PlaybackSnapshot, Never> { subject.eraseToAnyPublisher() }
    let ownsProgressPersistence = false
    private(set) var seeks: [TimeInterval] = []
    private(set) var rates: [Double] = []

    func play() {}
    func pause() {}
    func stop() {}
    func togglePlay() {}
    func seek(to time: TimeInterval) { seeks.append(time) }
    func skipForward(seconds: TimeInterval) {}
    func skipBackward(seconds: TimeInterval) {}
    func setPlaybackRate(_ rate: Double) { rates.append(rate) }
    func setVolume(_ volume: Double) {}
    func fadeOutAndPause(duration: TimeInterval, steps: Int) async {}

    func change(to next: PlaybackSnapshot, afterReads: Int) {
        deferredChange = (reads + afterReads, next)
    }
}

@MainActor
private final class StubNowPlayingUpdater: PlaybackNowPlayingUpdating {
    private(set) var refreshCount = 0

    func refreshNowPlayingInfo() { refreshCount += 1 }
}

@MainActor
private final class StubBookStarter: CarPlayReadAloudStarting {
    private(set) var played: [Book] = []
    private(set) var readAloudPlayed: [Book] = []
    var onPlay: ((Book) -> Void)?

    func play(_ book: Book, presentPlayer: Bool) {
        played.append(book)
        onPlay?(book)
    }

    func playAlignedReadAloud(_ book: Book, presentPlayer: Bool) {
        readAloudPlayed.append(book)
        onPlay?(book)
    }
}

@MainActor
private final class StubLibrary: CarPlayLibraryReading {
    var books: [Book] = []
    let cachedBookCount = 0
    var libraryChanged: AnyPublisher<Void, Never> { Empty<Void, Never>().eraseToAnyPublisher() }

    func bookInMemory(uniqueId: String) -> Book? {
        books.first { $0.uniqueId == uniqueId }
    }
}

@MainActor
private final class StubChapterSource: CarPlayChapterSource {
    var playerBook: Book?
    var playerChapters: [Chapter] = []
    var cached: [String: [Chapter]] = [:]

    func cachedChapters(bookId: String) -> [Chapter] { cached[bookId] ?? [] }
}

@MainActor
private final class StubDownloadState: CarPlayDownloadState {
    var downloaded: Set<String> = []
    var active: Set<String> = []
    var localReadaloud: Set<String> = []

    func downloadedAudiobookIds() async -> Set<String> { downloaded }

    func downloadedAudiobooks(from candidates: [Book], downloadedIds: Set<String>) async -> [Book] {
        CarPlayCatalog.downloadedAudiobooks(candidates, downloadedIds: downloadedIds) { $0.downloadKey }
    }

    func isAudiobookDownloaded(_ book: Book, downloadedIds: Set<String>) -> Bool {
        downloadedIds.contains(book.downloadKey)
    }

    func hasActiveDownload(_ book: Book) -> Bool { active.contains(book.downloadKey) }
    func hasLocalReadaloudEbook(_ book: Book) -> Bool { localReadaloud.contains(book.stableId) }
}

private func book(
    _ id: String,
    title: String? = nil,
    providerId: UUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!,
    mediaType: AppMediaType = .audiobook,
    chapters: [Chapter]? = nil
) -> Book {
    Book(
        id: id,
        title: title ?? id,
        duration: 600,
        chapters: chapters,
        mediaType: mediaType,
        providerId: providerId,
        libraryId: "library"
    )
}

private func readaloudBook(
    _ id: String,
    mediaType: AppMediaType = .audiobook,
    chapters: [Chapter]? = nil
) -> Book {
    var book = book(id, mediaType: mediaType, chapters: chapters)
    book.epub3Features = EPUB3Features(hasMediaOverlay: true)
    return book
}

private func chapter(_ id: String, start: Double) -> Chapter {
    Chapter(id: id, start: start, end: start + 30, title: id)
}

private func snapshot(
    currentBook: Book? = nil,
    duration: TimeInterval = 0,
    isLoaded: Bool = false,
    isLoading: Bool = false,
    errorDescription: String? = nil
) -> PlaybackSnapshot {
    PlaybackSnapshot(
        currentBook: currentBook,
        isPlaying: false,
        position: 0,
        duration: duration,
        playbackSpeed: 1,
        volume: 1,
        isLoaded: isLoaded,
        isLoading: isLoading,
        isOverlayPlaybackActive: false,
        errorDescription: errorDescription
    )
}

private func readySnapshot(for book: Book) -> PlaybackSnapshot {
    snapshot(currentBook: book, duration: 600, isLoaded: true)
}

private func connection(_ id: UUID, libraries: [String], isArchived: Bool = false) -> ServerConnection {
    var connection = ServerConnection(id: id, name: id.uuidString, url: "", type: .local)
    connection.selectedLibraryIds = Set(libraries)
    connection.isArchived = isArchived
    return connection
}
