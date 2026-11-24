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

    private func decodeBook(_ json: String) throws -> BookloreLegacyBook {
        try JSONDecoder().decode(BookloreLegacyBook.self, from: Data(json.utf8))
    }

    @Test(arguments: [
        #"{"content":[],"page":{"number":0,"size":0,"totalElements":0,"totalPages":0}}"#,
        #"{"content":[],"page":{"number":0,"size":100,"totalElements":101,"totalPages":1}}"#,
        #"{"content":[],"page":{"number":0,"size":100,"totalElements":0}}"#,
    ])
    func malformedPaginationCannotBecomeAnEmptyCatalog(payload: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BooklorePage<BookloreLegacyBook>.self, from: Data(payload.utf8))
        }
    }

    @Test(arguments: [true, false])
    func dualFormatCatalogIsIndependentOfPrimaryFile(audioFirst: Bool) throws {
        let primary = audioFirst ? "AUDIOBOOK" : "EPUB"
        let alternate = audioFirst ? "EPUB" : "AUDIOBOOK"
        let record = try decodeBook("""
            {"id":42,"metadata":{"title":"Mixed formats"},
             "primaryFile":{"id":1,"bookType":"\(primary)","fileName":"Primary.\(audioFirst ? "m4b" : "epub")"},
             "alternativeFormats":[{"id":2,"bookType":"\(alternate)","fileName":"Alternate.\(audioFirst ? "epub" : "m4b")"}],
             "epubProgress":{"percentage":25},"audiobookProgress":{"percentage":80}}
            """)
        let book = BookloreCatalogMapper.book(from: record, context: context)
        #expect(book.id == "42")
        #expect(book.mediaType == .ebook)
        #expect(book.ebookFormat == "epub")
        #expect(book.hasAlternateFormat)
        #expect(book.ebookProgress == 0.25)
        #expect(book.currentTime == 0)
        #expect(book.duration == nil)
        #expect(book.filePath?.hasSuffix(".epub") == true)
    }

    @Test @MainActor
    func resyncCorrectsMediaTypeWithoutRewindingNewerProgress() throws {
        let audiobookOnly = try decodeBook("""
            {"id":42,"metadata":{"title":"Mixed formats"},"primaryFile":{"bookType":"AUDIOBOOK","fileName":"Book.m4b"},
             "lastReadTime":"2026-03-01T00:00:00Z"}
            """)
        var previous = BookloreCatalogMapper.book(from: audiobookOnly, context: context)
        previous.duration = 100
        previous.currentTime = 80
        previous.lastUpdate = isoDate("2026-06-01T00:00:00Z")
        let record = BookRecord(from: previous)
        let dualFormat = try decodeBook("""
            {"id":42,"metadata":{"title":"Mixed formats"},"primaryFile":{"bookType":"AUDIOBOOK","fileName":"Book.m4b"},
             "alternativeFormats":[{"bookType":"EPUB","fileName":"Book.epub"}],
             "epubProgress":{"percentage":25},"lastReadTime":"2026-03-01T00:00:00Z"}
            """)
        var corrected = BookloreCatalogMapper.book(from: dualFormat, context: context)
        #expect(corrected.lastUpdate == isoDate("2026-03-01T00:00:00Z"))

        record.update(from: corrected)
        #expect(record.mediaType == AppMediaType.ebook.rawValue)
        #expect(record.filePath == "Book.epub")
        #expect(record.currentTime == 80)
        #expect(record.ebookProgress == nil)
        #expect(record.lastUpdate == isoDate("2026-06-01T00:00:00Z"))

        corrected.lastUpdate = isoDate("2026-07-01T00:00:00Z")
        record.update(from: corrected)
        #expect(record.ebookProgress == 0.25)
        #expect(record.currentTime == 0)
        #expect(record.lastUpdate == isoDate("2026-07-01T00:00:00Z"))
    }

    @Test(arguments: [true, false])
    func dualFormatWithoutFormatProgressKeepsCatalogProgress(audioFirst: Bool) throws {
        let primary = audioFirst ? "AUDIOBOOK" : "EPUB"
        let record = try decodeBook("""
            {"id":7,"metadata":{"title":"No detail"},
             "primaryFile":{"bookType":"\(primary)","fileName":"Primary.\(audioFirst ? "m4b" : "epub")"},
             "alternativeFormats":[{"bookType":"\(audioFirst ? "EPUB" : "AUDIOBOOK")","fileName":"Alternate.\(audioFirst ? "epub" : "m4b")"}],
             "koreaderProgress":{"percentage":40}}
            """)
        let book = BookloreCatalogMapper.book(from: record, context: context)
        #expect(book.id == "7")
        #expect(book.mediaType == .ebook)
        #expect(book.hasAlternateFormat)
        #expect(book.ebookProgress == (audioFirst ? 0 : 0.4))
        #expect(book.isFinished == false)
    }

    @Test func dualFormatKeepsFinishedDate() throws {
        let book = BookloreCatalogMapper.book(
            from: try decodeBook("""
                {"id":9,"metadata":{"title":"Done"},"primaryFile":{"bookType":"EPUB"},
                 "alternativeFormats":[{"bookType":"AUDIOBOOK"}],"dateFinished":"2026-02-01T00:00:00Z"}
                """),
            context: context
        )
        #expect(book.isFinished)
        #expect(book.ebookProgress == 0)
    }

    @Test @MainActor
    func companionAudiobookKeepsOriginalIdAsEbookAndDerivesStableCompanionId() throws {
        let provider = BookloreProvider(
            connection: ServerConnection(name: "Lab", url: "http://books.example:6060", type: .booklore)
        )
        let uuid = provider.connection.id.uuidString
        let record = try decodeBook("""
            {"id":42,"metadata":{"title":"Mixed formats"},"primaryFile":{"bookType":"EPUB","fileName":"Mixed.epub"},
             "alternativeFormats":[{"bookType":"AUDIOBOOK","fileName":"Mixed.m4b"}]}
            """)
        let providerContext = BookloreCatalogMapper.Context(
            providerId: provider.connection.id,
            libraryId: "1",
            source: .booklore,
            serverURL: "http://books.example:6060/"
        )
        var books = [BookloreCatalogMapper.book(from: record, context: providerContext)]
        let companions = provider.makeCompanionAudiobooks(forEbooks: &books)

        #expect(books[0].id == "42")
        #expect(books[0].mediaType == .ebook)
        #expect(books[0].hasAlternateFormat == false)
        #expect(books[0].linkedAudiobookStableId == "grimmory:\(uuid):grimmory-ab-42")
        #expect(companions.count == 1)
        #expect(companions[0].id == "grimmory-ab-42")
        #expect(companions[0].mediaType == .audiobook)
        #expect(companions[0].stableId == "grimmory:\(uuid):grimmory-ab-42")
        #expect(companions[0].linkedAudiobookStableId == "grimmory:\(uuid):42")
    }

    // Shape observed from the Grimmory nightly: no top-level title, paging nested under `page`.
    @Test func browsePageEnvelopeDecodesAndMapsAudiobook() throws {
        let fixture = Data(
            """
            {
              "content": [
                {
                  "id": 99,
                  "libraryId": 3,
                  "libraryName": "Audio",
                  "addedOn": "2026-03-21T03:13:41Z",
                  "lastReadTime": "2026-03-25T05:53:48Z",
                  "readStatus": "READING",
                  "personalRating": 8,
                  "metadata": {
                    "title": "Series Level Title",
                    "authors": ["Invented Author"],
                    "seriesName": "Invented Saga",
                    "seriesNumber": 1.0,
                    "publisher": "Invented Press",
                    "publishedDate": "2011-05-02",
                    "categories": ["Fantasy", "Adventure"],
                    "language": "en",
                    "narrator": "Invented Narrator",
                    "isbn13": "9780000000001",
                    "goodreadsRating": 4.4,
                    "audiobookCoverUpdatedOn": "2026-03-21T03:13:41Z",
                    "audiobookMetadata": { "durationSeconds": 3600 }
                  },
                  "primaryFile": {
                    "id": 199,
                    "bookId": 99,
                    "fileName": "Invented Audio File.m4b",
                    "filePath": "/books/Invented Audio File.m4b",
                    "book": true,
                    "folderBased": false,
                    "bookType": "AUDIOBOOK",
                    "extension": "m4b"
                  },
                  "alternativeFormats": [],
                  "audiobookProgress": { "positionMs": 450000, "trackIndex": 0, "percentage": 12.5 }
                }
              ],
              "page": { "number": 0, "size": 1, "totalElements": 64, "totalPages": 64, "cursor": "opaque" },
              "links": [{ "rel": ["next"], "href": "/api/v1/books/page?cursor=next", "type": "application/json" }]
            }
            """.utf8
        )
        let page = try JSONDecoder().decode(BooklorePage<BookloreLegacyBook>.self, from: fixture)
        #expect(page.page == 0)
        #expect(page.size == 1)
        #expect(page.totalElements == 64)
        #expect(page.totalPages == 64)
        #expect(page.hasNext)
        #expect(page.rejectedItems.isEmpty)

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
        #expect(book.duration == nil)
        #expect(book.currentTime == 0)
        #expect(book.ebookProgress == nil)
        #expect(book.isFinished == false)
        #expect(book.hideFromContinue == false)
        #expect(book.serverReadStatus == "READING")
        #expect(
            book.thumb
                == "http://books.example:6060/api/v1/media/book/99/audiobook-thumbnail?v=2026-03-21T03:13:41Z"
        )
        #expect(book.publisher == "Invented Press")
        #expect(book.genres == ["Adventure", "Fantasy"])
        #expect(book.language == "en")
        #expect(book.isbn == "9780000000001")
        #expect(book.personalRating == 4)
        #expect(book.goodreadsRating == 4.4)
        #expect(book.publishedYear == 2011)
        #expect(book.filePath == "Invented Audio File.m4b")
        #expect(book.addedAt == isoDate("2026-03-21T03:13:41Z"))
        #expect(book.lastUpdate == isoDate("2026-03-25T05:53:48Z"))
        #expect(book.hasAlternateFormat == false)
    }

    @Test func lastBrowsePageHasNoNext() throws {
        let page = try JSONDecoder().decode(
            BooklorePage<BookloreLegacyBook>.self,
            from: Data(#"{"content":[],"page":{"number":2,"size":100,"totalElements":250,"totalPages":3}}"#.utf8)
        )
        #expect(page.page == 2)
        #expect(!page.hasNext)
    }

    @Test func pageEnvelopeRequiresNestedPagingMetadata() {
        let appShapedPage = Data(
            """
            { "content": [], "page": 0, "size": 0, "totalElements": 0, "totalPages": 0, "hasNext": false }
            """.utf8
        )
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(BooklorePage<BookloreLegacyBook>.self, from: appShapedPage)
        }
    }

    @Test func malformedBrowseItemIsRejectedWithoutDroppingThePage() throws {
        let page = try JSONDecoder().decode(
            BooklorePage<BookloreLegacyBook>.self,
            from: Data(
                #"{"content":[{"id":1,"metadata":{"title":"A"}},{"metadata":{"title":"No id"}}],"page":{"number":0,"size":2,"totalElements":2,"totalPages":1}}"#
                    .utf8
            )
        )
        #expect(page.content.map(\.id.stringValue) == ["1"])
        #expect(page.rejectedItems.count == 1)
        #expect(page.rawItemCount == 2)
    }

    @Test func ebookWithMetadataRatingsAndFormatProgress() throws {
        let book = BookloreCatalogMapper.book(
            from: try decodeBook(
                """
                {
                  "id": "abc-7",
                  "addedOn": "2026-01-01T00:00:00Z",
                  "readStatus": "PAUSED",
                  "personalRating": 9,
                  "metadata": {
                    "title": "Invented Ebook",
                    "authors": ["Author B", "Author A"],
                    "goodreadsRating": 4.4,
                    "publishedDate": "2011-05-02"
                  },
                  "primaryFile": {
                    "fileName": "invented.epub",
                    "filePath": "/library/invented.epub",
                    "bookType": "EPUB",
                    "extension": "epub"
                  },
                  "epubProgress": { "percentage": 42, "cfi": "epubcfi(/6/2!/4/2:0)" }
                }
                """
            ),
            context: context
        )
        #expect(book.mediaType == .ebook)
        #expect(book.title == "Invented Ebook")
        #expect(book.author == "Author A, Author B")
        #expect(book.ebookFormat == "epub")
        #expect(book.hasAlternateFormat == false)
        #expect(book.ebookProgress == 0.42)
        #expect(book.currentTime == 0)
        #expect(book.hideFromContinue == true)
        #expect(book.serverReadStatus == "PAUSED")
        #expect(book.thumb == "http://books.example:6060/api/v1/media/book/abc-7/cover")
        #expect(book.filePath == "invented.epub")
        #expect(book.personalRating == 4.5)
        #expect(book.goodreadsRating == 4.4)
        #expect(book.publishedYear == 2011)
        #expect(book.libraryId == "fallback-lib")
        #expect(book.lastUpdate == isoDate("2026-01-01T00:00:00Z"))
    }

    @Test func fileTypeKeysResolveMediaTypeAndFormat() throws {
        let pdf = BookloreCatalogMapper.book(
            from: try decodeBook(#"{ "id": 1, "metadata": {"title": "P"}, "primaryFile": {"fileType": "PDF"} }"#),
            context: context
        )
        #expect(pdf.mediaType == .ebook)
        #expect(pdf.ebookFormat == "pdf")

        let audio = BookloreCatalogMapper.book(
            from: try decodeBook(#"{ "id": 2, "metadata": {"title": "F"}, "primaryFile": {"format": "AUDIOBOOK"} }"#),
            context: context
        )
        #expect(audio.mediaType == .audiobook)

        let comic = BookloreCatalogMapper.book(
            from: try decodeBook(#"{ "id": 3, "metadata": {"title": "C"}, "primaryFile": {"type": "CBZ"} }"#),
            context: context
        )
        #expect(comic.mediaType == .ebook)
        #expect(comic.ebookFormat == "cbz")
    }

    @Test func progressAndCompletionStates() throws {
        let pdf = BookloreCatalogMapper.book(
            from: try decodeBook(
                #"{ "id": 1, "metadata": {"title": "E"}, "primaryFile": {"bookType": "PDF"}, "pdfProgress": { "page": 3, "percentage": 55.0 } }"#
            ),
            context: context
        )
        #expect(pdf.ebookProgress == 0.55)
        #expect(pdf.isFinished == false)

        let readStatus = BookloreCatalogMapper.book(
            from: try decodeBook(#"{ "id": 2, "metadata": {"title": "R"}, "readStatus": "READ" }"#),
            context: context
        )
        #expect(readStatus.isFinished == true)
        #expect(readStatus.hideFromContinue == true)
        #expect(readStatus.serverReadStatus == "READ")

        let nearComplete = BookloreCatalogMapper.book(
            from: try decodeBook(#"{ "id": 3, "metadata": {"title": "N"}, "cbxProgress": { "percentage": 99.5 } }"#),
            context: context
        )
        #expect(nearComplete.isFinished == true)

        let finishedDate = BookloreCatalogMapper.book(
            from: try decodeBook(
                #"{ "id": 4, "metadata": {"title": "F"}, "dateFinished": "2026-02-01T00:00:00Z", "addedOn": "2026-01-01T00:00:00Z" }"#
            ),
            context: context
        )
        #expect(finishedDate.isFinished == true)
        #expect(finishedDate.lastUpdate == isoDate("2026-02-01T00:00:00Z"))
    }

    @Test func audiobookProgressDoesNotLeakIntoCatalogProgress() throws {
        let book = BookloreCatalogMapper.book(
            from: try decodeBook(
                """
                {"id":5,"metadata":{"title":"A"},"primaryFile":{"bookType":"AUDIOBOOK","fileName":"A.m4b"},
                 "audiobookProgress":{"positionMs":5000,"percentage":99.9}}
                """
            ),
            context: context
        )
        #expect(book.mediaType == .audiobook)
        #expect(book.currentTime == 0)
        #expect(book.isFinished == false)
    }

    @Test func minimalBookMapsWithDefaults() throws {
        let book = BookloreCatalogMapper.book(
            from: try decodeBook(#"{ "id": 11, "metadata": {"title": "Bare"} }"#),
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
        #expect(book.thumb == "http://books.example:6060/api/v1/media/book/11/cover")
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
            from: try decodeBook(#"{ "id": "str-id", "metadata": {"title": "S"}, "addedOn": 1774000000 }"#),
            context: context
        )
        #expect(stringId.id == "str-id")
        #expect(stringId.addedAt == Date(timeIntervalSince1970: 1_774_000_000))

        let epochMillis = BookloreCatalogMapper.book(
            from: try decodeBook(#"{ "id": 2, "metadata": {"title": "M"}, "addedOn": 1774000000000 }"#),
            context: context
        )
        #expect(epochMillis.addedAt == Date(timeIntervalSince1970: 1_774_000_000))

        let fractional = BookloreCatalogMapper.book(
            from: try decodeBook(#"{ "id": 3, "metadata": {"title": "F"}, "addedOn": "2026-03-21T03:13:41.500Z" }"#),
            context: context
        )
        #expect(fractional.addedAt == isoDate("2026-03-21T03:13:41.500Z"))
    }

    @Test func ebookMapsMetadataAndAlternativeFormats() throws {
        let record = try decodeBook(
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
                "id": 370,
                "bookType": "EPUB",
                "extension": "epub",
                "fileName": "invented-legacy.epub",
                "filePath": "/books/invented-legacy.epub"
              },
              "readStatus": "READING",
              "alternativeFormats": [
                { "id": 371, "bookType": "AUDIOBOOK", "fileName": "invented-legacy.m4b" }
              ]
            }
            """
        )
        let book = BookloreCatalogMapper.book(from: record, context: context)
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
        #expect(book.duration == nil)
        #expect(book.thumb == "http://books.example:6060/api/v1/media/book/37/cover")
        #expect(book.hasAlternateFormat == true)
        #expect(book.isFinished == false)
        #expect(book.hideFromContinue == false)
        #expect(book.serverReadStatus == "READING")
        #expect(book.addedAt == isoDate("2026-03-21T03:11:09Z"))
        #expect(book.lastUpdate == isoDate("2026-03-21T03:11:09Z"))
        #expect(book.genres == nil)
        #expect(book.filePath == "/books/invented-legacy.epub")
        #expect(record.files.map { $0.id?.stringValue } == ["370", "371"])
        #expect(record.isPrimary(record.files[0]))
        #expect(!record.isPrimary(record.files[1]))
    }

    @Test func audiobookTakesTitleFromFileName() throws {
        let record = try decodeBook(
            """
            {
              "id": 12,
              "name": "Fallback Name",
              "primaryFile": { "bookType": "AUDIOBOOK", "fileName": "Great Invented Tale.m4b" },
              "readStatus": "READ"
            }
            """
        )
        let book = BookloreCatalogMapper.book(from: record, context: context)
        #expect(book.mediaType == .audiobook)
        #expect(book.title == "Great Invented Tale")
        #expect(book.author == "Unknown Author")
        #expect(book.thumb == "http://books.example:6060/api/v1/media/book/12/audiobook-thumbnail")
        #expect(book.isFinished == true)
        #expect(book.hideFromContinue == true)
        #expect(book.hasAlternateFormat == false)
    }

    @Test func alternateKeySpellingsAndFilePathTitleFallback() throws {
        let typedFile = BookloreCatalogMapper.book(
            from: try decodeBook(#"{ "id": 8, "title": "T", "primaryFile": { "type": "PDF", "filename": "doc.pdf" } }"#),
            context: context
        )
        #expect(typedFile.mediaType == .ebook)
        #expect(typedFile.ebookFormat == "pdf")
        #expect(typedFile.title == "T")

        let pathTitled = BookloreCatalogMapper.book(
            from: try decodeBook(
                #"{ "id": 13, "primaryFile": { "bookType": "AUDIOBOOK", "filePath": "/x/Path Title.m4b" } }"#
            ),
            context: context
        )
        #expect(pathTitled.title == "/x/Path Title")

        let untitled = BookloreCatalogMapper.book(
            from: try decodeBook(#"{ "id": 14 }"#),
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

    @Test func coverURLsNormalizeSchemelessServerURLs() throws {
        let schemeless = BookloreCatalogMapper.Context(
            providerId: providerId,
            libraryId: "1",
            source: .booklore,
            serverURL: "books.example:8080/"
        )
        let book = BookloreCatalogMapper.book(
            from: try decodeBook(#"{ "id": 1, "metadata": {"title": "U"} }"#),
            context: schemeless
        )
        #expect(book.thumb == "http://books.example:8080/api/v1/media/book/1/cover")
    }
}
