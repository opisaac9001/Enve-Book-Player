import Foundation

enum PlayerBookmarkNavigation {
    static func audioSeekPosition(for bookmark: Bookmark, playbackBook: Book?) -> TimeInterval? {
        if bookmark.mediaType == .audiobook {
            return bookmark.position
        }
        guard playbackBook?.hasEPUB3MediaOverlay == true,
            bookmark.locator == nil,
            !bookmark.isRemotePlaceholder
        else {
            return nil
        }
        return bookmark.position
    }
}

public class PlayerBookmarkService {
    private let storageService: StorageService

    private let readerArtifacts: ReaderArtifactsStore

    init(storageService: StorageService = StorageService(), readerArtifacts: ReaderArtifactsStore = .shared) {
        self.readerArtifacts = readerArtifacts
        self.storageService = storageService
    }

    public func loadBookmarks(bookId: String) -> [Bookmark] {
        return readerArtifacts.loadBookmarks(bookId: bookId)
    }

    public func addBookmark(
        bookId: String,
        position: TimeInterval,
        locator: String?,
        title: String?,
        note: String?,
        mediaType: AppMediaType,
        chapterTitle: String? = nil,
        remoteID: Int? = nil,
        isRemotePlaceholder: Bool = false
    ) -> Bookmark {
        let autoTitle: String
        if let title = title, !title.isEmpty {
            autoTitle = title
        } else if mediaType == .ebook {
            autoTitle = chapterTitle ?? "Bookmark at \(Int(position * 100))%"
        } else if let chapter = chapterTitle, !chapter.isEmpty {
            autoTitle = "Bookmark - \(chapter)"
        } else {
            autoTitle = "Bookmark at \(PlaybackTime.clock(position))"
        }
        let bookmark = Bookmark(
            bookId: bookId,
            position: position,
            title: autoTitle,
            note: note,
            timestamp: Date(),
            locator: locator,
            mediaType: mediaType,
            chapterTitle: chapterTitle,
            remoteID: remoteID,
            isRemotePlaceholder: isRemotePlaceholder
        )
        var bookmarks = readerArtifacts.loadBookmarks(bookId: bookId)
        bookmarks.append(bookmark)
        readerArtifacts.saveBookmarks(bookId: bookId, bookmarks: bookmarks)
        return bookmark
    }

    public func addBookmark(bookId: String, position: TimeInterval, title: String?, note: String?) -> Bookmark {
        return addBookmark(bookId: bookId, position: position, locator: nil, title: title, note: note, mediaType: .audiobook)
    }

    public func deleteBookmark(_ bookmark: Bookmark) {
        var bookmarks = readerArtifacts.loadBookmarks(bookId: bookmark.bookId)
        bookmarks.removeAll { $0.id == bookmark.id }
        readerArtifacts.saveBookmarks(bookId: bookmark.bookId, bookmarks: bookmarks)
    }

    public func updateBookmark(_ bookmark: Bookmark) {
        var bookmarks = readerArtifacts.loadBookmarks(bookId: bookmark.bookId)
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
        }
        readerArtifacts.saveBookmarks(bookId: bookmark.bookId, bookmarks: bookmarks)
    }

    public func replaceBookmarks(bookId: String, bookmarks: [Bookmark]) {
        readerArtifacts.saveBookmarks(bookId: bookId, bookmarks: bookmarks)
    }
}
