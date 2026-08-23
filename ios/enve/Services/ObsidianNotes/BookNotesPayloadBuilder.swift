import Foundation

enum BookNotesPayloadBuilder {

    static func build(
        book: Book,
        annotations: [ReaderAnnotation],
        bookmarks: [Bookmark],
        lastSyncedAt: Date?,
        now: Date = Date()
    ) -> BookNotesPayload {
        let authors: [String] = {
            if let list = book.authors, !list.isEmpty { return list }
            if let single = book.author, !single.isEmpty { return [single] }
            return []
        }()

        let meta = BookNotesPayload.BookMeta(
            id: book.stableId,
            title: book.title,
            authors: authors,
            narrator: book.narrator,
            series: book.series,
            seriesNumber: book.seriesSequence,
            publishedYear: book.publishedYear,
            publisher: book.publisher,
            isbn: book.isbn,
            asin: book.asin,
            language: book.language,
            genres: book.genres ?? [],
            mediaType: book.mediaType.rawValue,
            coverPath: book.thumb,
            progress: clamp01(progressForBook(book))
        )

        let sortedAnnotations = annotations.sorted { $0.position < $1.position }
        let highlights: [BookNotesPayload.HighlightItem] =
            sortedAnnotations
            .filter { !$0.isRemotePlaceholder }
            .map { a in
                BookNotesPayload.HighlightItem(
                    id: a.id,
                    text: a.text,
                    note: nonEmpty(a.note),
                    colorHex: a.colorHex,
                    style: a.style.rawValue,
                    position: a.position,
                    chapterTitle: nonEmpty(a.chapterTitle),
                    createdAt: a.createdAt,
                    updatedAt: a.updatedAt
                )
            }

        let audiobookNotes: [BookNotesPayload.AudiobookNote] =
            bookmarks
            .filter { $0.mediaType == .audiobook && !$0.isRemotePlaceholder }
            .sorted { $0.position < $1.position }
            .map { b in
                BookNotesPayload.AudiobookNote(
                    id: b.id,
                    title: b.title,
                    note: nonEmpty(b.note),
                    timestampSeconds: b.position,
                    formattedTime: b.formattedTime,
                    chapterTitle: nonEmpty(b.chapterTitle),
                    createdAt: b.timestamp
                )
            }

        let ebookBookmarks: [BookNotesPayload.EbookBookmarkItem] =
            bookmarks
            .filter { $0.mediaType == .ebook && !$0.isRemotePlaceholder }
            .sorted { $0.position < $1.position }
            .map { b in
                BookNotesPayload.EbookBookmarkItem(
                    id: b.id,
                    title: b.title,
                    chapterTitle: nonEmpty(b.chapterTitle),
                    progress: b.position,
                    note: nonEmpty(b.note),
                    createdAt: b.timestamp
                )
            }

        var chapters: [String] = []
        var seen = Set<String>()
        for h in highlights {
            if let c = h.chapterTitle, seen.insert(c).inserted { chapters.append(c) }
        }
        for n in audiobookNotes {
            if let c = n.chapterTitle, seen.insert(c).inserted { chapters.append(c) }
        }

        return BookNotesPayload(
            book: meta,
            highlights: highlights,
            audiobookNotes: audiobookNotes,
            ebookBookmarks: ebookBookmarks,
            chapters: chapters,
            exportedAt: now,
            lastSyncedAt: lastSyncedAt
        )
    }

    private static func progressForBook(_ book: Book) -> Double {
        if book.mediaType == .ebook {
            return book.canonicalEbookProgress
        }
        if let duration = book.duration, duration > 0 {
            return book.currentTime / duration
        }
        return 0
    }

    private static func clamp01(_ v: Double) -> Double {
        if v.isNaN || !v.isFinite { return 0 }
        return min(max(v, 0), 1)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
