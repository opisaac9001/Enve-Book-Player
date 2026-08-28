import Foundation
import Testing

@testable import enve

struct BookloreCatalogMapperTests {
    private let providerId = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!

    private var context: BookloreCatalogMapper.Context {
        BookloreCatalogMapper.Context(
            providerId: providerId,
            libraryId: "fallback-lib",
            source: .booklore,
            serverURL: "http://books.example:6060/"
        )
    }

    private func isoDate(_ value: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)!
    }

    private func decodeSummary(_ json: String) throws -> BookloreBookSummary {
        try JSONDecoder().decode(BookloreBookSummary.self, from: Data(json.utf8))
    }

    private func decodeLegacy(_ json: String) throws -> BookloreLegacyBook {
        try JSONDecoder().decode(BookloreLegacyBook.self, from: Data(json.utf8))
    }

    @Test func appBooksPageEnvelopeDecodesAndMapsAudiobookSummary() throws {
        let fixture = Data(
            """
            {
              "content": [
                {
                  "id": 99,
                  "title": "Series Level Title",
                  "authors": ["Invented Author"],
                  "thumbnailUrl": "/api/books/99/cover",
                  "readStatus": "READING",
                  "seriesName": "Invented Saga",
                  "seriesNumber": 1.0,
                  "libraryId": 3,
                  "addedOn": "2026-03-21T03:13:41Z",
                  "lastReadTime": "2026-03-25T05:53:48Z",
                  "primaryFileType": "AUDIOBOOK",
                  "primaryFileName": "Invented Audio File.m4b",
                  "audiobookCoverUpdatedOn": "2026-03-21T03:13:41Z",
                  "publisher": "Invented Press",
                  "categories": ["Fantasy"],
                  "language": "en",
                  "narrator": "Invented Narrator",
                  "isbn13": "9780000000001",
                  "isPhysical": false,
                  "readProgress": 12.5,
                  "durationSeconds": 3600
                }
              ],
              "page": 0,
              "size": 1,
              "totalElements": 64,
              "totalPages": 64,
              "hasNext": true,
              "hasPrevious": false
            }
            """.utf8
        )
        let page = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: fixture)
        #expect(page.page == 0)
        #expect(page.size == 1)
        #expect(page.totalElements == 64)
        #expect(page.totalPages == 64)
        #expect(page.hasNext)
        #expect(!page.hasPrevious)

        let book = BookloreCatalogMapper.book(from: page.content[0], context: context)
        #expect(book.id == "99")
        #expect(book.providerId == providerId)
        #expect(book.libraryId == "3")
        #expect(book.source == .booklore)
        #expect(book.uniqueId == "\(providerId)_99")
        #expect(book.stableId == "grimmory:\(providerId.uuidString):99")
        #expect(book.mediaType == .audiobook)
        #expect(book.title == "Invented Audio File")
        #expect(book.author == "Invented Author")
        #expect(book.authors == ["Invented Author"])
        #expect(book.narrator == "Invented Narrator")
        #expect(book.series == "Invented Saga")
        #expect(book.seriesSequence == "1.0")
        #expect(book.seriesNumber == nil)
        #expect(book.duration == 3600)
        #expect(book.currentTime == 450)
        #expect(book.ebookProgress == nil)
        #expect(book.isFinished == false)
        #expect(book.hideFromContinue == false)
        #expect(book.serverReadStatus == "READING")
        #expect(
            book.thumb
                == "http://books.example:6060/api/v1/media/book/99/audiobook-thumbnail?v=2026-03-21T03:13:41Z"
        )
        #expect(book.publisher == "Invented Press")
        #expect(book.genres == ["Fantasy"])
        #expect(book.language == "en")
        #expect(book.isbn == "9780000000001")
        #expect(book.filePath == "Invented Audio File.m4b")
        #expect(book.addedAt == isoDate("2026-03-21T03:13:41Z"))
        #expect(book.lastUpdate == isoDate("2026-03-25T05:53:48Z"))
        #expect(book.hasAlternateFormat == false)
    }

    @Test func summaryPageEnvelopeRequiresPagingFields() {
        let fixture = Data(
            """
            { "content": [], "page": 0, "size": 0, "totalElements": 0, "totalPages": 0, "hasNext": false }
            """.utf8
        )
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: fixture)
        }
    }

    @Test func modernEbookSummaryWithPrimaryFileDetectsDualFormat() throws {
        let summary = try decodeSummary(
            """
            {
              "id": "abc-7",
              "title": "Invented Ebook",
              "authors": ["Author B", "Author A"],
              "thumbnailUrl": "/api/books/abc-7/cover",
              "audiobookCoverUpdatedOn": "2026-01-02T00:00:00Z",
              "primaryFile": {
                "fileName": "invented.epub",
                "filePath": "/library/invented.epub",
                "bookType": "EPUB",
                "extension": "epub"
              },
              "readProgress": 0.42,
              "readStatus": "PAUSED",
              "addedOn": "2026-01-01T00:00:00Z",
              "personalRating": 9.0,
              "goodreadsRating": 4.4,
              "publishedDate": "2011-05-02"
            }
            """
        )
        let book = BookloreCatalogMapper.book(from: summary, context: context)
        #expect(book.mediaType == .ebook)
        #expect(book.title == "Invented Ebook")
        #expect(book.author == "Author A, Author B")
        #expect(book.ebookFormat == "epub")
        #expect(book.hasAlternateFormat == true)
        #expect(book.ebookProgress == 0.42)
        #expect(book.currentTime == 0)
        #expect(book.hideFromContinue == true)
        #expect(book.serverReadStatus == "PAUSED")
        #expect(book.thumb == "http://books.example:6060/api/v1/media/book/abc-7/cover")
        #expect(book.filePath == "/library/invented.epub")
        #expect(book.personalRating == 4.5)
        #expect(book.goodreadsRating == 4.4)
        #expect(book.publishedYear == 2011)
        #expect(book.libraryId == "fallback-lib")
        #expect(book.lastUpdate == isoDate("2026-01-01T00:00:00Z"))
    }

    @Test func unknownPrimaryTypeWithAudiobookThumbnailBecomesAudiobook() throws {
        let summary = try decodeSummary(
            """
            { "id": 5, "title": "Fallback Title", "thumbnailUrl": "/api/v1/media/book/5/audiobook-thumbnail" }
            """
        )
        let book = BookloreCatalogMapper.book(from: summary, context: context)
        #expect(book.mediaType == .audiobook)
        #expect(book.title == "Fallback Title")
        #expect(book.author == "Unknown Author")
        #expect(book.thumb == "http://books.example:6060/api/v1/media/book/5/audiobook-thumbnail")
        #expect(book.duration == nil)
        #expect(book.currentTime == 0)
        #expect(book.ebookProgress == nil)
        #expect(book.hasAlternateFormat == false)
    }

    @Test func summaryAcceptsAlternateFileTypeKeys() throws {
        let pdf = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 1, "title": "P", "fileType": "PDF" }"#),
            context: context
        )
        #expect(pdf.mediaType == .ebook)
        #expect(pdf.ebookFormat == "pdf")

        let audio = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 2, "title": "F", "format": "AUDIOBOOK" }"#),
            context: context
        )
        #expect(audio.mediaType == .audiobook)

        let comic = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 3, "title": "C", "type": "CBZ" }"#),
            context: context
        )
        #expect(comic.mediaType == .ebook)
        #expect(comic.ebookFormat == "cbz")
    }

    @Test func summaryDurationFieldsFollowCurrentHeuristics() throws {
        let fromMs = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 1, "title": "D", "durationMs": 3600000 }"#),
            context: context
        )
        #expect(fromMs.duration == 3600)

        let plainSeconds = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 2, "title": "D", "duration": 7200 }"#),
            context: context
        )
        #expect(plainSeconds.duration == 7200)

        let largeValueTreatedAsMs = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 3, "title": "D", "duration": 36000000 }"#),
            context: context
        )
        #expect(largeValueTreatedAsMs.duration == 36000)

        let secondsFieldWins = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 4, "title": "D", "durationSeconds": 100, "duration": 999 }"#),
            context: context
        )
        #expect(secondsFieldWins.duration == 100)

        let zeroBecomesNil = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 5, "title": "D", "duration": 0 }"#),
            context: context
        )
        #expect(zeroBecomesNil.duration == nil)
    }

    @Test func summaryProgressAndCompletionStates() throws {
        let epubFallback = BookloreCatalogMapper.book(
            from: try decodeSummary(
                #"{ "id": 1, "title": "E", "primaryFileType": "EPUB", "epubProgress": { "percentage": 55.0 } }"#
            ),
            context: context
        )
        #expect(epubFallback.ebookProgress == 0.55)
        #expect(epubFallback.isFinished == false)

        let readStatus = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 2, "title": "R", "readStatus": "READ" }"#),
            context: context
        )
        #expect(readStatus.isFinished == true)
        #expect(readStatus.hideFromContinue == true)
        #expect(readStatus.serverReadStatus == "READ")

        let nearComplete = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 3, "title": "N", "readProgress": 99.5 }"#),
            context: context
        )
        #expect(nearComplete.isFinished == true)

        let finishedDate = BookloreCatalogMapper.book(
            from: try decodeSummary(
                #"{ "id": 4, "title": "F", "dateFinished": "2026-02-01T00:00:00Z", "addedOn": "2026-01-01T00:00:00Z" }"#
            ),
            context: context
        )
        #expect(finishedDate.isFinished == true)
        #expect(finishedDate.lastUpdate == isoDate("2026-02-01T00:00:00Z"))
    }

    @Test func minimalSummaryMapsWithDefaults() throws {
        let book = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 11, "title": "Bare" }"#),
            context: context
        )
        #expect(book.id == "11")
        #expect(book.title == "Bare")
        #expect(book.author == "Unknown Author")
        #expect(book.authors == nil)
        #expect(book.narrator == nil)
        #expect(book.mediaType == .ebook)
        #expect(book.ebookFormat == nil)
        #expect(book.duration == nil)
        #expect(book.thumb == nil)
        #expect(book.genres == nil)
        #expect(book.series == nil)
        #expect(book.publisher == nil)
        #expect(book.language == nil)
        #expect(book.isbn == nil)
        #expect(book.filePath == nil)
        #expect(book.ebookProgress == 0)
        #expect(book.isFinished == false)
        #expect(book.hideFromContinue == false)
        #expect(book.serverReadStatus == nil)
        #expect(book.libraryId == "fallback-lib")
        #expect(book.providerId == providerId)
    }

    @Test func flexibleIdAndDateFormsDecode() throws {
        let stringId = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": "str-id", "title": "S", "addedOn": 1774000000 }"#),
            context: context
        )
        #expect(stringId.id == "str-id")
        #expect(stringId.addedAt == Date(timeIntervalSince1970: 1_774_000_000))

        let epochMillis = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 2, "title": "M", "addedOn": 1774000000000 }"#),
            context: context
        )
        #expect(epochMillis.addedAt == Date(timeIntervalSince1970: 1_774_000_000))

        let fractional = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 3, "title": "F", "addedOn": "2026-03-21T03:13:41.500Z" }"#),
            context: context
        )
        #expect(fractional.addedAt == isoDate("2026-03-21T03:13:41.500Z"))
    }

    @Test func legacyRestEbookMapsMetadataAndAlternativeFormats() throws {
        let legacy = try decodeLegacy(
            """
            {
              "addedOn": "2026-03-21T03:11:09Z",
              "id": 37,
              "isPhysical": false,
              "libraryId": 2,
              "libraryName": "Shelf",
              "metadata": {
                "bookId": 37,
                "title": "Invented Legacy Title",
                "publisher": "Invented House",
                "language": "en",
                "authors": ["Legacy Author"],
                "seriesName": "Legacy Saga",
                "seriesNumber": 2.0,
                "description": "Invented description.",
                "narrator": "Legacy Narrator"
              },
              "primaryFile": {
                "bookType": "EPUB",
                "extension": "epub",
                "fileName": "invented-legacy.epub",
                "filePath": "/books/invented-legacy.epub"
              },
              "readStatus": "READING",
              "alternativeFormats": [
                { "bookType": "AUDIOBOOK", "fileName": "invented-legacy.m4b" }
              ]
            }
            """
        )
        let book = BookloreCatalogMapper.book(from: legacy, context: context)
        #expect(book.id == "37")
        #expect(book.providerId == providerId)
        #expect(book.libraryId == "2")
        #expect(book.source == .booklore)
        #expect(book.stableId == "grimmory:\(providerId.uuidString):37")
        #expect(book.mediaType == .ebook)
        #expect(book.ebookFormat == "epub")
        #expect(book.title == "Invented Legacy Title")
        #expect(book.author == "Legacy Author")
        #expect(book.narrator == "Legacy Narrator")
        #expect(book.series == "Legacy Saga")
        #expect(book.seriesSequence == "2.0")
        #expect(book.description == "Invented description.")
        #expect(book.publisher == "Invented House")
        #expect(book.duration == 0)
        #expect(book.thumb == "http://books.example:6060/api/v1/media/book/37/cover")
        #expect(book.hasAlternateFormat == true)
        #expect(book.isFinished == false)
        #expect(book.hideFromContinue == false)
        #expect(book.serverReadStatus == "READING")
        #expect(book.addedAt == isoDate("2026-03-21T03:11:09Z"))
        #expect(book.lastUpdate == isoDate("2026-03-21T03:11:09Z"))
        #expect(book.genres == [])
        #expect(book.filePath == nil)
    }

    @Test func legacyAudiobookTakesTitleFromFileName() throws {
        let legacy = try decodeLegacy(
            """
            {
              "id": 12,
              "name": "Fallback Name",
              "primaryFile": { "bookType": "AUDIOBOOK", "fileName": "Great Invented Tale.m4b" },
              "readStatus": "READ"
            }
            """
        )
        let book = BookloreCatalogMapper.book(from: legacy, context: context)
        #expect(book.mediaType == .audiobook)
        #expect(book.title == "Great Invented Tale")
        #expect(book.author == "Unknown Author")
        #expect(book.thumb == "http://books.example:6060/api/v1/media/book/12/audiobook-cover")
        #expect(book.isFinished == true)
        #expect(book.hideFromContinue == true)
        #expect(book.hasAlternateFormat == false)
    }

    @Test func legacyAlternateKeySpellingsAndFilePathTitleFallback() throws {
        let typedFile = BookloreCatalogMapper.book(
            from: try decodeLegacy(#"{ "id": 8, "title": "T", "primaryFile": { "type": "PDF", "filename": "doc.pdf" } }"#),
            context: context
        )
        #expect(typedFile.mediaType == .ebook)
        #expect(typedFile.ebookFormat == "pdf")
        #expect(typedFile.title == "T")

        let pathTitled = BookloreCatalogMapper.book(
            from: try decodeLegacy(
                #"{ "id": 13, "primaryFile": { "bookType": "AUDIOBOOK", "filePath": "/x/Path Title.m4b" } }"#
            ),
            context: context
        )
        #expect(pathTitled.title == "/x/Path Title")

        let untitled = BookloreCatalogMapper.book(
            from: try decodeLegacy(#"{ "id": 14 }"#),
            context: context
        )
        #expect(untitled.title == "Unknown")
    }

    @Test func legacyLibraryListDecodes() throws {
        let libraries = try JSONDecoder().decode(
            [BookloreLegacyLibrary].self,
            from: Data(
                """
                [
                  { "id": 2, "name": "Books", "allowedFormats": [] },
                  { "id": "5", "name": "Audio", "allowedFormats": ["AUDIOBOOK"] }
                ]
                """.utf8
            )
        )
        #expect(libraries.map(\.id.stringValue) == ["2", "5"])
        #expect(libraries.map(\.name) == ["Books", "Audio"])
        #expect(libraries[1].allowedFormats == ["AUDIOBOOK"])
    }

    @Test func coverURLsNormalizeBaseAndRewriteLegacyPaths() throws {
        let schemeless = BookloreCatalogMapper.Context(
            providerId: providerId,
            libraryId: "1",
            source: .booklore,
            serverURL: "books.example:8080/"
        )
        let relative = BookloreCatalogMapper.book(
            from: try decodeSummary(#"{ "id": 1, "title": "U", "thumbnailUrl": "/api/books/1/thumbnail" }"#),
            context: schemeless
        )
        #expect(relative.thumb == "http://books.example:8080/api/v1/media/book/1/thumbnail")

        let absolute = BookloreCatalogMapper.book(
            from: try decodeSummary(
                #"{ "id": 3, "title": "A", "thumbnailUrl": "https://cdn.example/api/books/3/thumbnail" }"#
            ),
            context: schemeless
        )
        #expect(absolute.thumb == "https://cdn.example/api/v1/media/book/3/thumbnail")
    }
}
