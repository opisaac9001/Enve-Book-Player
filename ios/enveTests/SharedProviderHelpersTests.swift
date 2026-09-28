import Foundation
import Testing

@testable import enve

struct ISO8601TimestampTests {
    @Test func parsesFractionalAndWholeSecondTimestamps() {
        #expect(ISO8601Timestamp.parse("2026-09-01T12:00:00Z") == Date(timeIntervalSince1970: 1_788_264_000))
        #expect(ISO8601Timestamp.parse("2026-09-01T12:00:00.250Z") == Date(timeIntervalSince1970: 1_788_264_000.25))
        #expect(ISO8601Timestamp.parse("2026-09-01T14:00:00+02:00") == Date(timeIntervalSince1970: 1_788_264_000))
    }

    @Test func rejectsMissingAndNonISOValues() {
        #expect(ISO8601Timestamp.parse(nil) == nil)
        #expect(ISO8601Timestamp.parse("") == nil)
        #expect(ISO8601Timestamp.parse("2026-09-01") == nil)
        #expect(ISO8601Timestamp.parse("2026-09-01 12:00:00") == nil)
        #expect(ISO8601Timestamp.parse("1788264000") == nil)
    }

    @Test func serverSpecificParsersKeepTheirExtraFormats() {
        #expect(FlexibleDate.parse("1788264000000") == Date(timeIntervalSince1970: 1_788_264_000))
        #expect(FlexibleDate.parse("2026-09-01T12:00:00.250Z") == Date(timeIntervalSince1970: 1_788_264_000.25))
        #expect(KavitaDate.parse("2026-09-01T12:00:00.1234567") != nil)
        #expect(HardcoverDateFormatter.parseISO8601("2026-09-01") != nil)
    }
}

struct KavitaDateTests {
    @Test func zonelessUtcTimestampsParseAsUtc() {
        #expect(KavitaDate.parse("2026-09-01T12:00:00") == Date(timeIntervalSince1970: 1_788_264_000))
        #expect(KavitaDate.parse("2026-09-01T12:00:00.2500000") == Date(timeIntervalSince1970: 1_788_264_000.25))
    }

    @Test func unsetProgressTimestampIsNil() {
        #expect(KavitaDate.parse("0001-01-01T00:00:00") == nil)
    }
}

struct PlaybackTimeTests {
    @Test(arguments: [
        (0.0, "0:00"),
        (59.9, "0:59"),
        (61, "1:01"),
        (3599, "59:59"),
        (3600, "1:00:00"),
        (36_061, "10:01:01"),
        (-5, "0:00"),
    ])
    func formatsClockTime(seconds: TimeInterval, expected: String) {
        #expect(PlaybackTime.clock(seconds) == expected)
    }
}

struct FinishedProgressThresholdTests {
    private func makeBook(mediaType: AppMediaType) -> Book {
        var book = Book(
            id: "threshold",
            title: "Threshold",
            author: nil,
            narrator: nil,
            source: .local,
            backendId: "unit",
            providerId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            libraryId: "library"
        )
        book.mediaType = mediaType
        return book
    }

    @Test func audiobookCompletesAtThreshold() {
        var book = makeBook(mediaType: .audiobook)
        book.duration = 1000
        book.currentTime = 989.9
        #expect(!book.isCompleted)
        book.currentTime = 1000 * Book.finishedProgressThreshold
        #expect(book.isCompleted)
    }

    @Test func ebookCompletesAtThreshold() {
        var book = makeBook(mediaType: .ebook)
        book.ebookProgress = 0.989
        #expect(!book.isCompleted)
        book.ebookProgress = Book.finishedProgressThreshold
        #expect(book.isCompleted)
    }

    @Test func audioFractionIsClampedToUnitRange() {
        #expect(Book.audioProgressFraction(currentTime: 50, duration: 100) == 0.5)
        #expect(Book.audioProgressFraction(currentTime: 150, duration: 100) == 1)
        #expect(Book.audioProgressFraction(currentTime: -5, duration: 100) == 0)
        #expect(Book.audioProgressFraction(currentTime: 50, duration: 0) == 0)
        #expect(Book.audioProgressFraction(currentTime: 50, duration: nil) == 0)
    }

    @Test func storedFractionClampsEbookProgress() {
        #expect(Book.storedProgressFraction(isEbook: true, currentTime: 0, duration: nil, ebookProgress: 0.42) == 0.42)
        #expect(Book.storedProgressFraction(isEbook: true, currentTime: 0, duration: nil, ebookProgress: 42) == 1)
        #expect(Book.storedProgressFraction(isEbook: false, currentTime: 30, duration: 60, ebookProgress: 0.9) == 0.5)
    }
}

struct AudioFileSupportTests {
    @Test func mapsAudioExtensionsCaseInsensitively() {
        #expect(AudioFileSupport.mimeType(forExtension: "M4B") == "audio/mp4")
        #expect(AudioFileSupport.mimeType(forExtension: "mp4") == "audio/mp4")
        #expect(AudioFileSupport.mimeType(forExtension: "mp3") == "audio/mpeg")
        #expect(AudioFileSupport.mimeType(forExtension: "opus") == "audio/ogg")
        #expect(AudioFileSupport.mimeType(forExtension: "wave") == "audio/wav")
        #expect(AudioFileSupport.mimeType(forExtension: "jpg") == nil)
    }

    @Test func resolvesMissingChapterEndsFromNextStartOrBookDuration() {
        let chapters = [
            Chapter(id: "1", start: 60, end: 0, title: "Two"),
            Chapter(id: "0", start: 0, end: 0, title: "One"),
        ]
        let resolved = AudioFileSupport.chaptersWithResolvedEnds(chapters, bookDuration: 90)
        #expect(resolved.map(\.id) == ["0", "1"])
        #expect(resolved.map(\.end) == [60, 90])
        #expect(resolved.map(\.index) == [0, 1])
    }
}

struct MediaBrowserClientTests {
    @Test func normalizesServerURLs() {
        #expect(MediaBrowserClient.normalizeServerURL(" jelly.lan:8096/ ") == "http://jelly.lan:8096")
        #expect(MediaBrowserClient.normalizeServerURL("jelly.lan:8920") == "https://jelly.lan:8920")
        #expect(MediaBrowserClient.normalizeServerURL("https://jelly.example/") == "https://jelly.example")
        #expect(MediaBrowserClient.normalizeServerURL("  ") == "  ")
    }

    @Test func authorizationHeaderAppendsTokenOnlyWhenPresent() {
        #expect(!MediaBrowserClient.authorizationHeader(token: nil).contains("Token="))
        #expect(MediaBrowserClient.authorizationHeader(token: "abc").hasSuffix(", Token=\"abc\""))
        #expect(MediaBrowserClient.authorizationHeader(token: nil).hasPrefix("MediaBrowser Client=\"Enve\""))
    }
}

struct HTMLTextTests {
    @Test func decodesNumericAndNamedEntities() {
        #expect("<p>It&#8217;s St. Jude time!</p>".strippingHTMLTags() == "It’s St. Jude time!")
        #expect("Tom &amp; Jerry &#x2014; &hellip;".strippingHTMLTags() == "Tom & Jerry — …")
        #expect("&bogus; stays".strippingHTMLTags() == "&bogus; stays")
    }
}

struct AudiobookshelfSeriesNameTests {
    @Test func minifiedSeriesNamesSplitIntoNameAndSequence() {
        #expect(
            AudiobookshelfProvider.seriesEntries(fromMinifiedName: "The Expanse #3, Space Opera #1.5")
                == [SeriesInfo(name: "The Expanse", sequence: "3"), SeriesInfo(name: "Space Opera", sequence: "1.5")]
        )
        #expect(AudiobookshelfProvider.seriesEntries(fromMinifiedName: "Jane Austen") == [SeriesInfo(name: "Jane Austen", sequence: nil)])
        #expect(AudiobookshelfProvider.seriesEntries(fromMinifiedName: nil).isEmpty)
    }
}
