import Combine
import Foundation

@MainActor
protocol CarPlayReadAloudStarting: BookPlaybackStarting {
    func playAlignedReadAloud(_ book: Book, presentPlayer: Bool)
}

@MainActor
protocol CarPlayConnectionObserving: ProviderConnectionAccessing {
    var connectionsChanged: AnyPublisher<Void, Never> { get }
}

@MainActor
protocol CarPlayLibraryReading: AnyObject {
    var cachedBookCount: Int { get }
    var libraryChanged: AnyPublisher<Void, Never> { get }

    func bookInMemory(uniqueId: String) -> Book?
}

@MainActor
protocol CarPlayProgressReading: AnyObject {
    func lastProgressUpdate(stableId: String) -> TimeInterval?
    func recentlyPlayed() -> [Book]
}

@MainActor
protocol CarPlayChapterSource: AnyObject {
    var playerBook: Book? { get }
    var playerChapters: [Chapter] { get }

    func cachedChapters(bookId: String) -> [Chapter]
}

@MainActor
protocol CarPlayDownloadState: AnyObject {
    func downloadedAudiobookIds() async -> Set<String>
    func downloadedAudiobooks(from candidates: [Book], downloadedIds: Set<String>) async -> [Book]
    func isAudiobookDownloaded(_ book: Book, downloadedIds: Set<String>) -> Bool
    func hasActiveDownload(_ book: Book) -> Bool
    func hasLocalReadaloudEbook(_ book: Book) -> Bool
}

@MainActor
struct CarPlayEnvironment {
    let controller: any PlaybackControlling
    let nowPlayingUpdater: any PlaybackNowPlayingUpdating
    let conflictResolver: (any PlaybackConflictResolving)?
    let playback: CarPlayPlaybackService
    let catalog: any BookQuerying
    let connections: any CarPlayConnectionObserving
    let library: any CarPlayLibraryReading
    let progress: any CarPlayProgressReading
    let downloads: any CarPlayDownloadState
}

@MainActor
final class CarPlayPlaybackService {
    private let controller: any PlaybackControlling
    private let nowPlayingUpdater: any PlaybackNowPlayingUpdating
    private let bookStarter: any CarPlayReadAloudStarting
    private let library: any CarPlayLibraryReading
    private let chapterSource: any CarPlayChapterSource
    private let downloads: any CarPlayDownloadState
    private let startTimeout: Duration
    private let startPollInterval: Duration

    init(
        controller: any PlaybackControlling,
        nowPlayingUpdater: any PlaybackNowPlayingUpdating,
        bookStarter: any CarPlayReadAloudStarting,
        library: any CarPlayLibraryReading,
        chapterSource: any CarPlayChapterSource,
        downloads: any CarPlayDownloadState,
        startTimeout: Duration = .seconds(8),
        startPollInterval: Duration = .milliseconds(100)
    ) {
        self.controller = controller
        self.nowPlayingUpdater = nowPlayingUpdater
        self.bookStarter = bookStarter
        self.library = library
        self.chapterSource = chapterSource
        self.downloads = downloads
        self.startTimeout = startTimeout
        self.startPollInterval = startPollInterval
    }

    func isCurrent(_ book: Book) -> Bool {
        controller.snapshot.currentBook?.uniqueId == book.uniqueId
    }

    func isReadaloudPlayable(_ book: Book) -> Bool {
        book.epub3Features?.hasMediaOverlay == true
    }

    func isDownloaded(_ book: Book, downloadedIds: Set<String>) -> Bool {
        if isReadaloudPlayable(book), downloads.hasLocalReadaloudEbook(book) {
            return true
        }

        guard book.mediaType != .ebook else { return false }

        if downloads.hasActiveDownload(book) {
            return false
        }
        return downloads.isAudiobookDownloaded(book, downloadedIds: downloadedIds)
    }

    func chapters(for book: Book) -> [Chapter] {
        if let chapters = book.chapters, !chapters.isEmpty {
            return chapters.sorted { $0.start < $1.start }
        }

        if let chapters = library.bookInMemory(uniqueId: book.uniqueId)?.chapters,
            !chapters.isEmpty
        {
            return chapters.sorted { $0.start < $1.start }
        }

        if let playerBook = chapterSource.playerBook,
            Self.isSameBook(playerBook, book),
            !chapterSource.playerChapters.isEmpty
        {
            return chapterSource.playerChapters.sorted { $0.start < $1.start }
        }

        for bookId in [book.stableId, book.id] {
            let cached = chapterSource.cachedChapters(bookId: bookId)
            if !cached.isEmpty {
                return cached.sorted { $0.start < $1.start }
            }
        }
        return []
    }

    nonisolated static func isSameBook(_ lhs: Book, _ rhs: Book) -> Bool {
        lhs.uniqueId == rhs.uniqueId || lhs.stableId == rhs.stableId || lhs.id == rhs.id
    }

    @discardableResult
    func play(_ book: Book) async -> Bool {
        let errorBeforeStart = controller.snapshot.errorDescription
        if isReadaloudPlayable(book) {
            playReadaloud(book)
        } else {
            bookStarter.play(book, presentPlayer: false)
        }
        let started = await waitForActivePlayback(of: book, ignoring: errorBeforeStart)
        if started {
            nowPlayingUpdater.refreshNowPlayingInfo()
        }
        return started
    }

    private func playReadaloud(_ book: Book) {
        var playbackBook = library.bookInMemory(uniqueId: book.uniqueId) ?? book
        let resolved = chapters(for: playbackBook)
        if !resolved.isEmpty {
            playbackBook.chapters = resolved
        }

        bookStarter.playAlignedReadAloud(playbackBook, presentPlayer: false)
    }

    private func waitForActivePlayback(of book: Book, ignoring errorBeforeStart: String?) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: startTimeout)
        while true {
            let snapshot = controller.snapshot
            if snapshot.currentBook?.uniqueId == book.uniqueId,
                snapshot.isLoaded,
                !snapshot.isLoading,
                snapshot.duration > 0
            {
                return true
            }
            if let error = snapshot.errorDescription, error != errorBeforeStart {
                return false
            }
            guard clock.now < deadline else { break }
            try? await Task.sleep(for: startPollInterval)
        }
        return controller.snapshot.currentBook?.uniqueId == book.uniqueId
    }
}

enum CarPlayCatalog {
    nonisolated static func continueListeningOrder(_ books: [Book], lastUpdated: [String: TimeInterval]) -> [Book] {
        books.enumerated().sorted { a, b in
            let ta = lastUpdated[a.element.stableId]
            let tb = lastUpdated[b.element.stableId]
            switch (ta, tb) {
            case let (x?, y?): return x > y
            case (nil, nil): return a.offset < b.offset
            case (.some, nil): return true
            case (nil, .some): return false
            }
        }.map(\.element)
    }

    nonisolated static func downloadedAudiobooks(
        _ candidates: [Book],
        downloadedIds: Set<String>,
        identifier: @Sendable (Book) -> String
    ) -> [Book] {
        var seen = Set<String>()
        var books: [Book] = []
        for book in candidates where book.mediaType != .ebook {
            guard downloadedIds.contains(identifier(book)) else { continue }
            if seen.insert(book.stableId).inserted {
                books.append(book)
            }
        }
        return books
    }

    nonisolated static func alphabeticalGroups(
        _ books: [Book],
        maxSections: Int,
        maxItems: Int
    ) -> [(letter: String, books: [Book])] {
        let grouped = Dictionary(grouping: books) { book -> String in
            book.title.first.flatMap { $0.isLetter ? String($0).uppercased() : nil } ?? "#"
        }

        let sortedKeys = grouped.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs < rhs
        }

        let perSectionCap = max(1, maxItems / max(1, min(sortedKeys.count, maxSections)))

        var groups: [(letter: String, books: [Book])] = []
        var totalItems = 0
        for letter in sortedKeys.prefix(maxSections) {
            guard let letterBooks = grouped[letter], !letterBooks.isEmpty else { continue }
            let remaining = maxItems - totalItems
            guard remaining > 0 else { break }
            let take = min(letterBooks.count, perSectionCap, remaining)
            groups.append((letter, Array(letterBooks.prefix(take))))
            totalItems += take
        }
        return groups
    }

    nonisolated static func connectionSignature(_ connections: [ServerConnection]) -> String {
        connections
            .filter { !$0.isArchived }
            .map { "\($0.id.uuidString):\(($0.selectedLibraryIds ?? []).sorted().joined(separator: ","))" }
            .sorted()
            .joined(separator: "|")
    }
}
