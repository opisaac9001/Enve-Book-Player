import Foundation
import Logging

extension BookloreProvider {
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    func makeCompanionAudiobooks(forEbooks ebooks: inout [Book]) -> [Book] {
        var companions: [Book] = []
        for index in ebooks.indices {
            let ebook = ebooks[index]
            guard ebook.mediaType == .ebook,
                ebook.hasAlternateFormat,
                ebook.epub3Features?.hasMediaOverlay != true,
                !ebook.id.hasPrefix(Self.companionAudiobookIDPrefix)
            else { continue }

            let audiobookStableId = "grimmory:\(connection.id.uuidString):\(Self.companionAudiobookIDPrefix + ebook.id)"

            ebooks[index].linkedAudiobookStableId = audiobookStableId
            ebooks[index].hasAlternateFormat = false

            companions.append(makeCompanionAudiobook(forEbook: ebook))
        }
        return companions
    }

    func makeCompanionAudiobook(forEbook ebook: Book) -> Book {
        let audiobookId = Self.companionAudiobookIDPrefix + ebook.id
        let ebookStableId = "grimmory:\(connection.id.uuidString):\(ebook.id)"

        var audiobook = Book(
            id: audiobookId,
            title: ebook.title,
            author: ebook.author,
            authors: ebook.authors,
            narrator: nil,
            seriesInfo: ebook.seriesInfo,
            duration: nil,
            coverURL: absoluteURL(
                from: fallbackCoverPath(for: ebook.id, mediaType: .audiobook),
                mediaType: .audiobook
            ),
            mediaType: .audiobook,
            hideFromContinue: false,
            description: ebook.description,
            genres: ebook.genres,
            publisher: ebook.publisher,
            currentTime: 0,
            isFinished: false,
            lastUpdate: ebook.lastUpdate,
            libraryId: ebook.libraryId,
            providerId: connection.id,
            source: .booklore,
            rawMetadata: nil,
            filePath: nil,
            publishedYear: ebook.publishedYear,
            personalRating: ebook.personalRating,
            goodreadsRating: ebook.goodreadsRating
        )
        audiobook.linkedAudiobookStableId = ebookStableId
        return audiobook
    }

    func mapToBook(_ detail: BookloreLegacyBook, fallbackLibraryId: String) -> Book {
        var book = BookloreCatalogMapper.book(from: detail, context: catalogMapperContext(libraryId: fallbackLibraryId))

        // Book details prefer the ebook format's own progress over KOReader or Kobo progress.
        if book.mediaType == .ebook,
            let formatProgress = BookloreBookMapper.fraction(
                fromPercent: detail.epubProgress?.percentage ?? detail.pdfProgress?.percentage
            )
        {
            book.ebookProgress = formatProgress
            book.isFinished = book.isFinished || formatProgress >= Book.finishedProgressThreshold
        }

        let readAloudTags: Set<String> = ["read aloud", "readaloud", "read-aloud"]
        if book.genres?.contains(where: { readAloudTags.contains($0.lowercased()) }) == true {
            book.epub3Features = EPUB3Features(hasMediaOverlay: true, hasFixedLayout: false, smilFileCount: 1)
        }

        if detail.epubProgress == nil, let page = detail.pdfProgress?.page {
            book.epubLocator = "{\"page\":\(page)}"
        }
        return book
    }
}
