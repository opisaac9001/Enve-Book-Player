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
    private static func permittedSession() -> ProfileSession? {
        let coordinator = ProfileSwitchCoordinator.shared
        guard !coordinator.isLocked, coordinator.activeSession.isOwner, !coordinator.activeSession.isRetired else { return nil }
        return coordinator.activeSession
    }

    static func downloadedAudiobooks(matching query: String? = nil) async -> [SiriAudiobookDescriptor] {
        guard let session = permittedSession() else { return [] }
        let books = await downloadedBooks(session: session)
        guard !session.isRetired, permittedSession() === session else { return [] }
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
        guard let session = permittedSession(), let book = await resolveDownloadedAudiobook(identifier: identifier, session: session),
            !session.isRetired, permittedSession() === session else {
            throw SiriAudiobookError.audiobookUnavailable
        }
        try await startPlayback(book, session: session)
        return book
    }

    @discardableResult
    static func resumeCurrentAudiobook() async throws -> Book {
        guard let session = permittedSession() else { throw SiriAudiobookError.noCurrentAudiobook }
        let playback = session.playback.composition.controller
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

        if let current = session.engine.playback.currentBook,
            current.mediaType == .audiobook,
            !current.isPodcastEpisode
        {
            try await startPlayback(current, session: session)
            return current
        }

        guard let lastID = session.playerState.loadLastPlayedBookId(),
            !lastID.isEmpty,
            let lastBook = await resolveAudiobook(identifier: lastID, session: session)
        else {
            throw SiriAudiobookError.noCurrentAudiobook
        }
        try await startPlayback(lastBook, session: session)
        return lastBook
    }

    private static func downloadedBooks(session: ProfileSession) async -> [Book] {
        let storage = session.localStorage
        let downloadedIDs = await Task.detached(priority: .userInitiated) {
            Set(storage.downloadedAudiobookIds())
        }.value
        guard !downloadedIDs.isEmpty else { return [] }

        let storedDownloads = await session.appState.bookStore.downloadedAudiobooks(storageKeys: downloadedIDs)
        var byStableID = Dictionary(uniqueKeysWithValues: storedDownloads.map { ($0.stableId, $0) })

        if byStableID.count < downloadedIDs.count {
            let cachedMatches = session.appState.allBooks.filter {
                isDownloadedAudiobook($0, downloadedIDs: downloadedIDs, session: session)
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
            let storedMatches = await session.appState.bookStore.booksByAnyIds(lookupIDs)
            for book in storedMatches.values where isDownloadedAudiobook(book, downloadedIDs: downloadedIDs, session: session) {
                byStableID[book.stableId] = book
            }
        }

        return Array(byStableID.values)
    }

    private static func resolveDownloadedAudiobook(identifier: String, session: ProfileSession) async -> Book? {
        guard let book = await resolveAudiobook(identifier: identifier, session: session) else { return nil }
        let storage = session.localStorage
        let downloadedIDs = await Task.detached(priority: .userInitiated) {
            Set(storage.downloadedAudiobookIds())
        }.value
        guard isDownloadedAudiobook(book, downloadedIDs: downloadedIDs, session: session) else { return nil }
        return book
    }

    private static func resolveAudiobook(identifier: String, session: ProfileSession) async -> Book? {
        let stored = await session.appState.bookStore.book(byAnyId: identifier)
        let book =
            stored
            ?? session.bookProgress.loadRecentlyPlayed().first {
                $0.stableId == identifier || $0.id == identifier || $0.uniqueId == identifier
            }
        guard let book, book.mediaType == .audiobook, !book.isPodcastEpisode else { return nil }
        return book
    }

    private static func isDownloadedAudiobook(_ book: Book, downloadedIDs: Set<String>, session: ProfileSession) -> Bool {
        book.mediaType == .audiobook
            && !book.isPodcastEpisode
            && session.localStorage.isAudiobookDownloaded(book, downloadedIds: downloadedIDs)
    }

    private static func startPlayback(_ book: Book, session: ProfileSession) async throws {
        guard !session.isRetired, permittedSession() === session else { throw SiriAudiobookError.audiobookUnavailable }
        let playback = session.playback.composition.controller
        let initialSnapshot = playback.snapshot
        if initialSnapshot.currentBook?.stableId == book.stableId, initialSnapshot.isLoaded {
            if !initialSnapshot.isPlaying {
                playback.play()
            }
            return
        }

        session.engine.playback.play(book, presentPlayer: false)

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            guard !session.isRetired, permittedSession() === session else { throw SiriAudiobookError.audiobookUnavailable }
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
