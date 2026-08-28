import Foundation

struct SiriAudiobookDescriptor: Sendable, Equatable {
    let id: String
    let title: String
    let author: String?
    let narrator: String?

    nonisolated func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return [title, author, narrator]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

enum SiriAudiobookError: LocalizedError {
    case audiobookUnavailable
    case noCurrentAudiobook
    case playbackFailed(String?)

    var errorDescription: String? {
        switch self {
        case .audiobookUnavailable:
            "That downloaded audiobook is no longer available in Enve."
        case .noCurrentAudiobook:
            "There isn't a current audiobook to resume in Enve."
        case .playbackFailed(let reason):
            reason ?? "Enve couldn't start audiobook playback."
        }
    }
}

@MainActor
enum SiriAudiobookService {
    static func downloadedAudiobooks(matching query: String? = nil) async -> [SiriAudiobookDescriptor] {
        let books = await downloadedBooks()
        let descriptors = books.map {
            SiriAudiobookDescriptor(
                id: $0.stableId,
                title: $0.title,
                author: $0.author,
                narrator: $0.narrator
            )
        }
        let filtered =
            query.map { value in
                descriptors.filter { $0.matches(value) }
            } ?? descriptors
        return filtered.sorted {
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id < $1.id
        }
    }

    static func downloadedAudiobooks(with identifiers: [String]) async -> [SiriAudiobookDescriptor] {
        guard !identifiers.isEmpty else { return [] }
        let descriptors = await downloadedAudiobooks()
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        return identifiers.compactMap { byID[$0] }
    }

    @discardableResult
    static func playDownloadedAudiobook(identifier: String) async throws -> Book {
        guard let book = await resolveDownloadedAudiobook(identifier: identifier) else {
            throw SiriAudiobookError.audiobookUnavailable
        }
        try await startPlayback(book)
        return book
    }

    @discardableResult
    static func resumeCurrentAudiobook() async throws -> Book {
        let playback = ActivePlayback.controller
        let snapshot = playback.snapshot
        if let current = snapshot.currentBook,
            current.mediaType == .audiobook,
            !current.isPodcastEpisode,
            snapshot.isLoaded
        {
            if !snapshot.isPlaying {
                playback.play()
            }
            return current
        }

        if let current = EnveEngine.shared.playback.currentBook,
            current.mediaType == .audiobook,
            !current.isPodcastEpisode
        {
            try await startPlayback(current)
            return current
        }

        guard let lastID = PlayerStateStore.shared.loadLastPlayedBookId(),
            !lastID.isEmpty,
            let lastBook = await resolveAudiobook(identifier: lastID)
        else {
            throw SiriAudiobookError.noCurrentAudiobook
        }
        try await startPlayback(lastBook)
        return lastBook
    }

    private static func downloadedBooks() async -> [Book] {
        let storage = LocalStorageManager.shared
        let downloadedIDs = await Task.detached(priority: .userInitiated) {
            Set(storage.downloadedAudiobookIds())
        }.value
        guard !downloadedIDs.isEmpty else { return [] }

        let storedDownloads = await AppState.shared.bookStore.downloadedAudiobooks(storageKeys: downloadedIDs)
        var byStableID = Dictionary(uniqueKeysWithValues: storedDownloads.map { ($0.stableId, $0) })

        if byStableID.count < downloadedIDs.count {
            let cachedMatches = AppState.shared.allBooks.filter {
                isDownloadedAudiobook($0, downloadedIDs: downloadedIDs)
            }
            for book in cachedMatches {
                byStableID[book.stableId] = book
            }
        }

        if byStableID.count < downloadedIDs.count {
            var lookupIDs = downloadedIDs
            for id in downloadedIDs where id.contains(":") {
                if let bare = id.split(separator: ":").last, !bare.isEmpty {
                    lookupIDs.insert(String(bare))
                }
            }
            let storedMatches = await AppState.shared.bookStore.booksByAnyIds(lookupIDs)
            for book in storedMatches.values where isDownloadedAudiobook(book, downloadedIDs: downloadedIDs) {
                byStableID[book.stableId] = book
            }
        }

        return Array(byStableID.values)
    }

    private static func resolveDownloadedAudiobook(identifier: String) async -> Book? {
        guard let book = await resolveAudiobook(identifier: identifier) else { return nil }
        let storage = LocalStorageManager.shared
        let downloadedIDs = await Task.detached(priority: .userInitiated) {
            Set(storage.downloadedAudiobookIds())
        }.value
        guard isDownloadedAudiobook(book, downloadedIDs: downloadedIDs) else { return nil }
        return book
    }

    private static func resolveAudiobook(identifier: String) async -> Book? {
        let stored = await AppState.shared.bookStore.book(byAnyId: identifier)
        let book =
            stored
            ?? BookProgressStore.shared.loadRecentlyPlayed().first {
                $0.stableId == identifier || $0.id == identifier || $0.uniqueId == identifier
            }
        guard let book, book.mediaType == .audiobook, !book.isPodcastEpisode else { return nil }
        return book
    }

    private static func isDownloadedAudiobook(_ book: Book, downloadedIDs: Set<String>) -> Bool {
        book.mediaType == .audiobook
            && !book.isPodcastEpisode
            && LocalStorageManager.shared.isAudiobookDownloaded(book, downloadedIds: downloadedIDs)
    }

    private static func startPlayback(_ book: Book) async throws {
        let playback = ActivePlayback.controller
        let initialSnapshot = playback.snapshot
        if initialSnapshot.currentBook?.stableId == book.stableId, initialSnapshot.isLoaded {
            if !initialSnapshot.isPlaying {
                playback.play()
            }
            return
        }

        EnveEngine.shared.playback.play(book, presentPlayer: false)

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let snapshot = playback.snapshot
            if snapshot.currentBook?.stableId == book.stableId,
                snapshot.isLoaded,
                !snapshot.isLoading
            {
                if !snapshot.isPlaying {
                    playback.play()
                }
                return
            }
            if let error = snapshot.errorDescription {
                throw SiriAudiobookError.playbackFailed(error)
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw SiriAudiobookError.playbackFailed(playback.snapshot.errorDescription)
    }
}
