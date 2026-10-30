import Foundation
import Testing
import UIKit

@testable import enve

// Fixtures mirror docs/architecture/listening-position-sharing.md; update both together.
private enum Fixture {
    static let full =
        #"{"a":["Brandon Sanderson"],"asin":"B003ZWFO7E","dur":163980000,"k":"enve.position","n":["Michael Kramer","Kate Reading"],"pos":3723500,"q":"1","s":"The Stormlight Archive","t":"The Way of Kings","v":1}"#
    static let minimal = #"{"dur":3600000,"k":"enve.position","pos":0,"t":"Untitled Recording","v":1}"#
    static let escaped =
        #"{"a":["Antoine de Saint-Exupéry"],"dur":5400000,"isbn":"9782070612758","k":"enve.position","pos":1,"t":"Le \"Petit\" Prince \\ Édition","v":1}"#
}

@MainActor
struct ListeningPositionPayloadTests {
    @Test func fullFixtureRoundTripsCanonically() throws {
        let payload = try ListeningPositionPayload.decode(Fixture.full)

        #expect(payload.positionMilliseconds == 3_723_500)
        #expect(payload.durationMilliseconds == 163_980_000)
        #expect(payload.title == "The Way of Kings")
        #expect(payload.authors == ["Brandon Sanderson"])
        #expect(payload.narrators == ["Michael Kramer", "Kate Reading"])
        #expect(payload.series == "The Stormlight Archive")
        #expect(payload.seriesSequence == "1")
        #expect(payload.asin == "B003ZWFO7E")
        #expect(payload.isbn == nil)
        #expect(payload.position == 3723.5)
        #expect(payload.encoded() == Fixture.full)
    }

    @Test func minimalAndEscapedFixturesRoundTripCanonically() throws {
        #expect(try ListeningPositionPayload.decode(Fixture.minimal).encoded() == Fixture.minimal)

        let escaped = try ListeningPositionPayload.decode(Fixture.escaped)
        #expect(escaped.title == #"Le "Petit" Prince \ Édition"#)
        #expect(escaped.encoded() == Fixture.escaped)
    }

    @Test func decoderIgnoresUnknownKeysAndNeverTreatsThemAsLinks() throws {
        let payload = try ListeningPositionPayload.decode(
            #"{"dur":3600000,"k":"enve.position","pos":10,"t":"Book","url":"http://192.168.1.2/api","v":1}"#
        )
        #expect(payload.encoded() == #"{"dur":3600000,"k":"enve.position","pos":10,"t":"Book","v":1}"#)
    }

    @Test(arguments: [
        (#"{"dur":3600000,"k":"enve.position","pos":0,"t":"X","v":3}"#, ListeningPositionPayloadError.unsupportedVersion(3)),
        (#"{"dur":3600000,"k":"enve.position","pos":0,"t":"X","v":0}"#, .invalidField("v")),
        (#"{"dur":3600000,"k":"enve.position","pos":0,"t":"X","v":true}"#, .invalidField("v")),
        (#"{"dur":3600000,"k":"enve.position","pos":0,"t":"X"}"#, .invalidField("v")),
        (#"{"dur":3600000,"k":"enve.position","pos":-1,"t":"X","v":1}"#, .invalidField("pos")),
        (#"{"dur":3600000,"k":"enve.position","pos":3600001,"t":"X","v":1}"#, .invalidField("pos")),
        (#"{"dur":3600000,"k":"enve.position","pos":1.5,"t":"X","v":1}"#, .invalidField("pos")),
        (#"{"dur":3600000,"k":"enve.position","pos":"10","t":"X","v":1}"#, .invalidField("pos")),
        (#"{"dur":0,"k":"enve.position","pos":0,"t":"X","v":1}"#, .invalidField("dur")),
        (#"{"dur":3600000001,"k":"enve.position","pos":0,"t":"X","v":1}"#, .invalidField("dur")),
        (#"{"dur":3600000,"k":"enve.position","pos":0,"t":"","v":1}"#, .invalidField("t")),
        (#"{"dur":3600000,"k":"enve.position","pos":0,"t":"A\nB","v":1}"#, .invalidField("t")),
        (#"{"a":["1","2","3","4","5"],"dur":3600000,"k":"enve.position","pos":0,"t":"X","v":1}"#, .invalidField("a")),
        (#"{"a":"Single","dur":3600000,"k":"enve.position","pos":0,"t":"X","v":1}"#, .invalidField("a")),
        (#"{"asin":"b003zwfo7e","dur":3600000,"k":"enve.position","pos":0,"t":"X","v":1}"#, .invalidField("asin")),
        (#"{"dur":3600000,"isbn":"12345","k":"enve.position","pos":0,"t":"X","v":1}"#, .invalidField("isbn")),
        (#"{"dur":3600000,"k":"other.app","pos":0,"t":"X","v":1}"#, .notListeningPosition),
        ("https://example.com/position?t=10", .notListeningPosition),
        ("[1,2,3]", .notListeningPosition),
    ])
    func decoderRejectsInvalidCodes(text: String, expected: ListeningPositionPayloadError) {
        #expect(throws: expected) { try ListeningPositionPayload.decode(text) }
    }

    @Test func richReadingFixturePreservesEveryRepresentation() throws {
        let fixture = ##"{"c":"epubcfi(/6/4!/4/2/1:7)","f":"epub","h":"OPS/chapter.xhtml","k":"enve.position","l":"{\"href\":\"OPS/chapter.xhtml\",\"locations\":{\"cssSelector\":\"#p3\",\"domRange\":{\"start\":{\"charOffset\":7,\"cssSelector\":\"#p3\",\"textNodeIndex\":0}},\"fragments\":[\"p3\"],\"position\":12,\"progression\":0.5,\"totalProgression\":0.25},\"text\":{\"after\":\" after\",\"before\":\"before \",\"highlight\":\"A passage\"},\"type\":\"application/xhtml+xml\"}","m":"reading","o":500000,"p":250000,"t":"A Book","v":2}"##
        let payload = try ListeningPositionPayload.decode(fixture)
        #expect(payload.encoded() == fixture)
        let reading = try #require(payload.readingLocation)
        #expect(reading.epubCFI == "epubcfi(/6/4!/4/2/1:7)")
        #expect(reading.progression == 0.25)
        let book = Book(id: "rich", ratingKey: "rich", title: "A Book", mediaType: .ebook, ebookFormat: "EPUB")
        let restored = try #require(SharedReadingLocator.object(reading.locatorJSON(for: book)))
        let locations = try #require(restored["locations"] as? [String: Any])
        #expect(locations["cfi"] as? String == reading.epubCFI)
        #expect(locations["position"] as? Int == 12)
        #expect(locations["cssSelector"] as? String == "#p3")
        #expect(locations["domRange"] != nil)
        #expect((restored["text"] as? [String: String])?["highlight"] == "A passage")
        let image = try #require(ListeningPositionQRCode.image(for: payload.encoded()))
        #expect(ListeningPositionQRCode.messages(inImageData: try #require(image.pngData())) == [fixture])
    }

    @Test func readingSenderUnwrapsCheckpointsWithoutExportingPrivateIdentity() throws {
        var book = Book(id: "rich", ratingKey: "rich", title: "A Book", mediaType: .ebook, ebookFormat: "EPUB")
        book.ebookProgress = 0.25
        book.epubLocator = ##"{"schemaVersion":1,"bookKey":"private-account","publicationFingerprint":"private-file","writerEpoch":99,"href":"OPS/chapter.xhtml","epubCFI":"epubcfi(/6/4!/4/2/1:7)","resourceProgression":0.5,"totalProgression":0.25,"cssSelector":"#p3","textQuote":{"exact":"The passage","prefix":"Before","suffix":"After"},"sourceEngine":"foliate"}"##
        let payload = try #require(ListeningPositionPayload(book: book))
        #expect(payload.readingLocation?.epubCFI == "epubcfi(/6/4!/4/2/1:7)")
        #expect(payload.readingLocation?.readiumLocatorJSON?.contains("The passage") == true)
        #expect(payload.readingLocation?.href == "OPS/chapter.xhtml")
        #expect(!payload.encoded().contains("private"))
        #expect(!payload.encoded().contains("writerEpoch"))
        #expect(try ListeningPositionPayload.decode(payload.encoded()) == payload)
    }

    @Test func cfiOnlySharesRetainPercentageFallbackAcrossFormats() throws {
        var book = Book(id: "cfi", ratingKey: "cfi", title: "Book", mediaType: .ebook, ebookFormat: "EPUB")
        book.epubLocator = "epubcfi(/6/4!/4/2/1:7)"
        book.ebookProgress = 0.25
        let reading = try #require(ListeningPositionPayload(book: book)?.readingLocation)
        #expect(reading.epubCFI == book.epubLocator)
        #expect(reading.readiumLocatorJSON == nil)
        #expect(reading.locatorJSON(for: book)?.contains("epubcfi(") == true)
        book.ebookFormat = "FB2"
        #expect(reading.locatorJSON(for: book)?.contains("epubcfi(") == false)
        #expect(reading.locatorJSON(for: book)?.contains("0.25") == true)
    }

    @Test func invalidRichLocationsAreRejected() throws {
        for raw in [
            #"{"href":"https://private.example/book","type":"application/xhtml+xml","locations":{}}"#,
            #"{"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"position":true}}"#,
            #"{"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"progression":2}}"#,
            #"{"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"domRange":{"start":{"cssSelector":"p","textNodeIndex":-1}}}}"#,
        ] {
            #expect(throws: ListeningPositionPayloadError.self) {
                try ListeningPositionReadingLocation(format: "epub", progressionUnits: 0, readiumLocatorJSON: raw)
            }
        }
        #expect(throws: ListeningPositionPayloadError.self) {
            try ListeningPositionReadingLocation(format: "epub", progressionUnits: 0, epubCFI: "https://private.example")
        }
    }

    @Test func sharingNeverDropsPreciseAnchorsToFitTheCode() throws {
        var book = Book(id: "large", ratingKey: "large", title: "Book", mediaType: .ebook, ebookFormat: "EPUB")
        let quote = String(repeating: "A", count: 1900)
        let locator = SharedReadingLocator.encoded(["href": "chapter.xhtml", "type": "application/xhtml+xml",
            "locations": ["progression": 0.5, "totalProgression": 0.25, "cfi": "epubcfi(/6/4!/4/2/1:7)"],
            "text": ["highlight": quote, "before": quote]])
        book.epubLocator = locator
        book.ebookProgress = 0.25
        #expect(ListeningPositionPayload(book: book) == nil)
    }

    @Test func nativeFractionsKeepTheirPrecisionAndCanonicalDecimalEncoding() throws {
        let raw = #"{"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"progression":1e-7,"totalProgression":0.25}}"#
        let reading = try ListeningPositionReadingLocation(format: "epub", progressionUnits: 250000,
            href: "chapter.xhtml", resourceProgressionUnits: 0, readiumLocatorJSON: raw)
        #expect(reading.readiumLocatorJSON?.contains("0.0000001") == true)
        let book = Book(id: "fine", ratingKey: "fine", title: "Book", mediaType: .ebook, ebookFormat: "EPUB")
        let object = try #require(SharedReadingLocator.object(reading.locatorJSON(for: book)))
        #expect((object["locations"] as? [String: Any])?["progression"] as? Double == 0.0000001)
        let tiny = try SharedReadingLocator.sanitized(raw.replacingOccurrences(of: "1e-7", with: "1e-200"), strict: true)
        #expect(tiny.contains("0." + String(repeating: "0", count: 199) + "1"))
    }

    @Test(arguments: [
        "epubcfi(/6/4[a^,b]!/4/2/1:7)",
        "epubcfi(/6/4[a/b]!/4/2/1:7)",
        "epubcfi(/6/4[a!b]!/4/2/1:7)",
        "epubcfi(/6/4!/4/2/1:7[before,after/words;s=b])",
        "epubcfi(/6/4!/4/2,/1:7[before,after],/1:12[end,words])",
    ])
    func cfiAssertionsPreserveTheirDelimiters(_ cfi: String) throws {
        let location = try ListeningPositionReadingLocation(format: "epub", progressionUnits: 250000, epubCFI: cfi)
        let payload = try ListeningPositionPayload(positionMilliseconds: 0, durationMilliseconds: 0,
            title: "Book", readingLocation: location)
        #expect(try ListeningPositionPayload.decode(payload.encoded()).readingLocation?.epubCFI == cfi)
    }

    @Test func richCodeAtByteLimitCanBeImported() throws {
        let location = try ListeningPositionReadingLocation(format: "epub", progressionUnits: 250000,
            epubCFI: "epubcfi(/6/4!/4/2/1:7)")
        let payload = try ListeningPositionPayload(positionMilliseconds: 0, durationMilliseconds: 0, title: "Book", readingLocation: location)
        let message = payload.encoded() + String(repeating: " ", count: ListeningPositionPayload.maxEncodedBytes - payload.encoded().utf8.count)
        let image = try #require(ListeningPositionQRCode.image(for: message))
        let data = try #require(image.pngData())
        let decoded = try #require(ListeningPositionQRCode.messages(inImageData: data).first)
        #expect(decoded == message)
        #expect(try ListeningPositionPayload.decode(decoded) == payload)
    }

    @Test func readingFixtureRoundTripsCanonically() throws {
        let fixture = #"{"f":"epub","k":"enve.position","m":"reading","p":250000,"t":"A Book","v":2}"#
        let payload = try ListeningPositionPayload.decode(fixture)
        let location = try #require(payload.readingLocation)
        #expect(location.format == "epub")
        #expect(location.progression == 0.25)
        #expect(payload.positionMilliseconds == 0)
        #expect(payload.durationMilliseconds == 0)
        #expect(payload.encoded() == fixture)
    }

    @Test func readingResourceAndFixedPageLocationsRoundTrip() throws {
        let resource = #"{"a":["Author"],"f":"epub","h":"OPS/chapter%20one.xhtml","k":"enve.position","m":"reading","o":750000,"p":250000,"t":"A Book","v":2}"#
        #expect(try ListeningPositionPayload.decode(resource).encoded() == resource)
        let comic = #"{"f":"comic","k":"enve.position","m":"reading","p":0,"page":1,"pages":20,"t":"Issue 1","v":2}"#
        #expect(try ListeningPositionPayload.decode(comic).encoded() == comic)
        let unknownPDFCount = #"{"f":"pdf","k":"enve.position","m":"reading","p":500000,"page":10,"t":"A Book","v":2}"#
        #expect(try ListeningPositionPayload.decode(unknownPDFCount).encoded() == unknownPDFCount)
        for units in [Int64(0), 1_000_000] {
            let location = try ListeningPositionReadingLocation(format: "epub", progressionUnits: units)
            let payload = try ListeningPositionPayload(positionMilliseconds: 0, durationMilliseconds: 0, title: "Book", readingLocation: location)
            #expect(try ListeningPositionPayload.decode(payload.encoded()) == payload)
        }
    }

    @Test(arguments: [
        #"{"f":"epub","k":"enve.position","m":"reading","p":-1,"t":"Book","v":2}"#,
        #"{"f":"epub","k":"enve.position","m":"reading","p":1000001,"t":"Book","v":2}"#,
        #"{"f":"epub","k":"enve.position","m":"reading","p":true,"t":"Book","v":2}"#,
        #"{"f":"epub","k":"enve.position","m":"reading","p":1.5,"t":"Book","v":2}"#,
        #"{"f":"epub","k":"enve.position","m":"reading","p":"1","t":"Book","v":2}"#,
        #"{"f":"EPUB","k":"enve.position","m":"reading","p":1,"t":"Book","v":2}"#,
        #"{"f":"epub","k":"enve.position","p":1,"t":"Book","v":2}"#,
        #"{"f":"epub","k":"enve.position","m":"reading","p":1,"pos":0,"t":"Book","v":2}"#,
        #"{"dur":1,"f":"epub","k":"enve.position","m":"reading","p":1,"t":"Book","v":2}"#,
        #"{"dur":1,"k":"enve.position","m":"reading","pos":0,"t":"Book","v":1}"#,
        #"{"f":"pdf","k":"enve.position","m":"reading","p":1,"pages":20,"t":"Book","v":2}"#,
        #"{"f":"comic","k":"enve.position","m":"reading","p":1,"page":0,"t":"Book","v":2}"#,
        #"{"f":"comic","k":"enve.position","m":"reading","p":1,"page":21,"pages":20,"t":"Book","v":2}"#,
        #"{"f":"epub","h":"OPS/a.xhtml","k":"enve.position","m":"reading","p":1,"t":"Book","v":2}"#,
        #"{"f":"epub","k":"enve.position","m":"reading","o":1,"p":1,"t":"Book","v":2}"#,
        #"{"f":"epub","h":"OPS/a.xhtml","k":"enve.position","m":"reading","o":1000001,"p":1,"t":"Book","v":2}"#,
        #"{"f":"epub","k":"enve.position","m":"reading","p":0,"page":10,"t":"A Book","v":2}"#,
        #"{"f":"pdf","h":"OPS/a.xhtml","k":"enve.position","m":"reading","o":0,"p":0,"t":"Book","v":2}"#,
    ])
    func decoderRejectsInvalidReadingCodes(_ text: String) {
        #expect(throws: ListeningPositionPayloadError.self) { try ListeningPositionPayload.decode(text) }
    }

    @Test(arguments: ["https://example.com/book", "/chapter.xhtml", "../chapter.xhtml", "OPS/%2e%2e/chapter.xhtml", "chapter.xhtml#fragment", "chapter.xhtml?token=example", "OPS/%00.xhtml", "%FF.xhtml", "%C3.xhtml", "OPS/\u{200D}.xhtml", "OPS\\chapter.xhtml"])
    func readingResourceNeverAcceptsExternalOrUnsafePaths(_ href: String) {
        #expect(throws: ListeningPositionPayloadError.self) {
            try ListeningPositionReadingLocation(format: "epub", progressionUnits: 0, href: href, resourceProgressionUnits: 0)
        }
    }

    @Test func readingResourceAcceptsEncodedUnicode() throws {
        let location = try ListeningPositionReadingLocation(format: "epub", progressionUnits: 0,
            href: "%C3%A9.xhtml", resourceProgressionUnits: 0)
        #expect(location.href == "%C3%A9.xhtml")
    }

    @Test func readingSenderKeepsTextAnchorsWithoutExternalURLs() throws {
        var book = Book(id: "reading", ratingKey: "reading", title: "A Book", mediaType: .ebook, ebookFormat: "EPUB")
        book.ebookProgress = 0.25
        book.epubLocator = #"{"href":"OPS/chapter.xhtml","locations":{"progression":0.5,"totalProgression":0.25},"text":{"highlight":"Private reading text"},"url":"https://private.example/"}"#
        let payload = try #require(ListeningPositionPayload(book: book))
        #expect(payload.readingLocation?.href == "OPS/chapter.xhtml")
        #expect(payload.readingLocation?.resourceProgressionUnits == 500_000)
        #expect(payload.readingLocation?.progressionUnits == 250_000)
        #expect(payload.encoded().contains("Private reading text"))
        #expect(!payload.encoded().contains("private.example"))
        book.epubLocator = #"{"href":"https://private.example/book","locations":{"progression":0.5}}"#
        #expect(try #require(ListeningPositionPayload(book: book)).readingLocation?.href == nil)
    }

    @Test func readingSenderAndRecipientUseNativePageLocators() throws {
        var comic = Book(id: "comic", ratingKey: "comic", title: "Issue", mediaType: .ebook, ebookFormat: "CBZ")
        comic.comicMetadata = ComicMetadata(seriesID: "series", pageCount: 21)
        comic.ebookProgress = 0.5
        comic.epubLocator = "cbz-page:10"
        let comicLocation = try #require(ListeningPositionPayload(book: comic)?.readingLocation)
        #expect(comicLocation.page == 11)
        #expect(comicLocation.pageCount == 21)
        #expect(comicLocation.locatorJSON(for: comic) == "cbz-page:10")
        #expect(comicLocation.progression(for: comic) == 0.5)

        var pdf = Book(id: "pdf", ratingKey: "pdf", title: "PDF", mediaType: .ebook, ebookFormat: "PDF")
        pdf.epubLocator = #"{"page":7}"#
        pdf.ebookProgress = 0.35
        let pdfLocation = try #require(ListeningPositionPayload(book: pdf)?.readingLocation)
        #expect(pdfLocation.page == 8)
        #expect(pdfLocation.pageCount == nil)
        #expect(pdfLocation.locatorJSON(for: pdf) == #"{"page":7,"enveSharedPosition":true}"#)
        let fallback = try #require(pdfLocation.locatorJSON(for: comic)?.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: fallback) as? [String: Any])
        #expect(object["enveSharedPosition"] as? Bool == true)
        #expect(object["href"] == nil)
        #expect((object["locations"] as? [String: Any])?["totalProgression"] as? Double == 0.35)
    }

    @Test func podcastEpisodesCanShareAudioTimestamps() throws {
        let episode = Book(id: "episode", ratingKey: "episode", title: "Episode", duration: 60, isPodcastEpisode: true, mediaType: .podcast)
        #expect(try #require(ListeningPositionPayload(book: episode)).durationMilliseconds == 60_000)
    }

    @Test func decoderRejectsOversizeAndNonFiniteInput() {
        let padding = String(repeating: " ", count: ListeningPositionPayload.maxEncodedBytes)
        #expect(throws: ListeningPositionPayloadError.tooLarge) {
            try ListeningPositionPayload.decode(Fixture.minimal + padding)
        }
        #expect(throws: ListeningPositionPayloadError.self) {
            try ListeningPositionPayload.decode(#"{"dur":3600000,"k":"enve.position","pos":1e400,"t":"X","v":1}"#)
        }
    }

    @Test func senderSanitizesLibraryMetadata() throws {
        let book = Book(
            id: "1",
            ratingKey: "1",
            title: "  The   Way\nof Kings ",
            authors: ["Brandon Sanderson", "brandon sanderson"],
            narrator: "Michael Kramer, Kate Reading",
            duration: 163_980,
            series: "The Stormlight Archive",
            seriesNumber: 1,
            isbn: "978-0-7653-2635-5",
            asin: "b003zwfo7e"
        )

        let payload = try #require(ListeningPositionPayload(book: book, position: 3723.5009, duration: 163_980))

        #expect(payload.title == "The Way of Kings")
        #expect(payload.authors == ["Brandon Sanderson"])
        #expect(payload.narrators == ["Michael Kramer", "Kate Reading"])
        #expect(payload.seriesSequence == "1")
        #expect(payload.asin == "B003ZWFO7E")
        #expect(payload.isbn == "9780765326355")
        #expect(payload.positionMilliseconds == 3_723_500)
        #expect(try ListeningPositionPayload.decode(payload.encoded()) == payload)
    }

    @Test func senderClampsPositionAndRefusesUnusableBooks() throws {
        let book = Book(id: "1", ratingKey: "1", title: "Book", duration: 60)
        #expect(try #require(ListeningPositionPayload(book: book, position: 75, duration: 60)).positionMilliseconds == 60_000)
        #expect(try #require(ListeningPositionPayload(book: book, position: -4, duration: 60)).positionMilliseconds == 0)
        #expect(ListeningPositionPayload(book: book, position: .nan, duration: 60) == nil)
        #expect(ListeningPositionPayload(book: book, position: 0, duration: .greatestFiniteMagnitude) == nil)
        #expect(try #require(ListeningPositionPayload(book: book, position: .greatestFiniteMagnitude, duration: 60)).positionMilliseconds == 60_000)
        #expect(ListeningPositionPayload(book: book, position: 0, duration: 0) == nil)
        #expect(ListeningPositionPayload(book: Book(id: "2", ratingKey: "2", title: "Ebook", mediaType: .ebook), position: 0, duration: 60) == nil)
        #expect(ListeningPositionPayload(book: Book(id: "3", ratingKey: "3", title: " \n ", duration: 60), position: 0, duration: 60) == nil)
    }

    @Test func senderKeepsTheCodeWithinTheByteBudget() throws {
        let longName = String(repeating: "\u{1F4DA}", count: 200)
        let book = Book(
            id: "1",
            ratingKey: "1",
            title: String(repeating: "\u{00E9}", count: 400),
            authors: (0..<6).map { "\($0)\(longName)" },
            narrator: (0..<6).map { "\($0)\(longName)" }.joined(separator: ", "),
            duration: 3600,
            series: longName
        )

        let payload = try #require(ListeningPositionPayload(book: book, position: 10, duration: 3600))

        #expect(payload.encoded().utf8.count <= ListeningPositionPayload.maxEncodedBytes)
        #expect(payload.title.unicodeScalars.count == ListeningPositionPayload.maxTitleLength)
        #expect(try ListeningPositionPayload.decode(payload.encoded()) == payload)
    }

    @Test func exportedImageCanBeImported() throws {
        let book = Book(id: "qr-roundtrip", ratingKey: "qr-roundtrip", title: "The Shared Book", duration: 3600)
        let payload = try #require(ListeningPositionPayload(book: book, position: 1234.5, duration: 3600))
        let image = try #require(ListeningPositionQRCode.image(for: payload.encoded()))
        let data = try #require(image.pngData())
        let messages = ListeningPositionQRCode.messages(inImageData: data)
        #expect(messages == [payload.encoded()])
        #expect(try ListeningPositionPayload.decode(#require(messages.first)) == payload)
    }


    @Test func rejectsMalformedAndOversizedImages() {
        #expect(ListeningPositionQRCode.messages(inImageData: Data()).isEmpty)
        #expect(ListeningPositionQRCode.messages(inImageData: Data(repeating: 0xFF, count: ListeningPositionQRCode.maxImageBytes + 1)).isEmpty)
        for count in [1, 7, 32, 256, 1024, 4096] {
            #expect(ListeningPositionQRCode.messages(inImageData: Data(repeating: 0x89, count: count)).isEmpty)
        }
    }

    @Test func malformedPayloadStress() {
        var state: UInt64 = 42
        for _ in 0..<2000 {
            var bytes = [UInt8]()
            for _ in 0..<128 {
                state = state &* 6364136223846793005 &+ 1
                bytes.append(UInt8(truncatingIfNeeded: state >> 32))
            }
            let input = String(decoding: bytes, as: UTF8.self)
            #expect(throws: ListeningPositionPayloadError.self) { try ListeningPositionPayload.decode(input) }
        }
        for depth in [8, 64, 256, 500] {
            let input = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
            #expect(throws: ListeningPositionPayloadError.self) { try ListeningPositionPayload.decode(input) }
        }
    }


    @Test func rejectsImagesBeyondDimensionLimit() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 17000, height: 1), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 17000, height: 1))
        }
        let data = try #require(image.pngData())
        #expect(data.count < ListeningPositionQRCode.maxImageBytes)
        #expect(ListeningPositionQRCode.messages(inImageData: data).isEmpty)
    }

}
