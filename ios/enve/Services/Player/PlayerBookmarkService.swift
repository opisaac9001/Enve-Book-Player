import Foundation

public class PlayerBookmarkService {
    private let storageService: StorageService

    public init(storageService: StorageService = StorageService()) {
        self.storageService = storageService
    }

    public func loadBookmarks(bookId: String) -> [Bookmark] {
        return ReaderArtifactsStore.shared.loadBookmarks(bookId: bookId)
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
            autoTitle = "Bookmark at \(formatTime(position))"
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
        var bookmarks = ReaderArtifactsStore.shared.loadBookmarks(bookId: bookId)
        bookmarks.append(bookmark)
        ReaderArtifactsStore.shared.saveBookmarks(bookId: bookId, bookmarks: bookmarks)
        return bookmark
    }

    public func addBookmark(bookId: String, position: TimeInterval, title: String?, note: String?) -> Bookmark {
        return addBookmark(bookId: bookId, position: position, locator: nil, title: title, note: note, mediaType: .audiobook)
    }

    public func deleteBookmark(_ bookmark: Bookmark) {
        var bookmarks = ReaderArtifactsStore.shared.loadBookmarks(bookId: bookmark.bookId)
        bookmarks.removeAll { $0.id == bookmark.id }
        ReaderArtifactsStore.shared.saveBookmarks(bookId: bookmark.bookId, bookmarks: bookmarks)
    }

    public func updateBookmark(_ bookmark: Bookmark) {
        var bookmarks = ReaderArtifactsStore.shared.loadBookmarks(bookId: bookmark.bookId)
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
        }
        ReaderArtifactsStore.shared.saveBookmarks(bookId: bookmark.bookId, bookmarks: bookmarks)
    }

    public func replaceBookmarks(bookId: String, bookmarks: [Bookmark]) {
        ReaderArtifactsStore.shared.saveBookmarks(bookId: bookId, bookmarks: bookmarks)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let remainingSeconds = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}
