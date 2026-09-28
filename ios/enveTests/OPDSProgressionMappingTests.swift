import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSProgressionMappingTests {
    private static let providerId = UUID(uuidString: "0F17E6A0-5555-4222-8333-444444444444")!

    // MARK: Enve position to references

    @Test func aReadiumLocatorBecomesAResourceReferenceWithItsMostPreciseFragments() {
        let point = OPDSProgressionMapping.point(
            forEbookLocator: """
                {"href":"chapter1.xhtml","type":"application/xhtml+xml","title":"Chapter 1",
                 "locations":{"totalProgression":0.0174,"cfi":"epubcfi(/6/4[chap01]!/4/2/2)","fragments":["par36"]},
                 "text":{"highlight":"It was expected"}}
                """
        )

        #expect(point.resourcePath == "chapter1.xhtml")
        #expect(point.htmlID == "par36")
        #expect(point.scrollToText == "It was expected")
        #expect(point.epubCFI == "/6/4[chap01]!/4/2/2")
        #expect(
            point.references == [
                "chapter1.xhtml#:~:text=It%20was%20expected",
                "chapter1.xhtml#par36",
                "#epubcfi(/6/4[chap01]!/4/2/2)",
            ]
        )
    }

    @Test func anIdentifierOnTheHrefIsUsedWhenTheLocatorNamesNoFragments() {
        let point = OPDSProgressionMapping.point(
            forEbookLocator: #"{"href":"chapter1.xhtml#par36","locations":{"totalProgression":0.5}}"#
        )

        #expect(point.resourcePath == "chapter1.xhtml")
        #expect(point.htmlID == "par36")
    }

    @Test func aPDFLocatorBecomesAOneBasedPageReference() {
        #expect(
            OPDSProgressionMapping.point(forEbookLocator: #"{"page":5}"#).references == ["#page=6"]
        )
    }

    @Test func aComicPageHasNoReferenceEnveCanWriteAndFallsBackToProgression() {
        let point = OPDSProgressionMapping.point(forEbookLocator: "cbz-page:3")

        #expect(point.references.isEmpty)
    }

    @Test func aReadAloudAudioLocatorIsNotWrittenAsAResourcePath() {
        let point = OPDSProgressionMapping.point(
            forEbookLocator: #"{"href":"audiobook://track/2","type":"audio/mpeg","locations":{"totalProgression":0.3}}"#
        )

        #expect(point.references.isEmpty)
    }

    @Test func theChapterTitleIsLiftedOutOfTheLocatorForTheDraftsTitleMember() {
        #expect(
            OPDSProgressionMapping.chapterTitle(
                inEbookLocator: #"{"href":"c1.xhtml","title":"Chapter 1 - A New Dawn","locations":{}}"#
            ) == "Chapter 1 - A New Dawn"
        )
        #expect(OPDSProgressionMapping.chapterTitle(inEbookLocator: #"{"href":"c1.xhtml","title":"  "}"#) == nil)
        #expect(OPDSProgressionMapping.chapterTitle(inEbookLocator: "cbz-page:3") == nil)
    }

    // MARK: References to an Enve position

    @Test func aResourceReferenceBecomesAReadiumLocator() throws {
        let point = OPDSProgressionPoint(
            resourcePath: "chapter1.xhtml",
            scrollToText: "It was expected",
            htmlID: "par36",
            epubCFI: "/6/4[chap01]!/4/2/2"
        )

        let locator = try #require(
            OPDSProgressionMapping.ebookLocator(for: Self.book(format: "epub"), point: point, progression: 0.0174)
        )
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(locator.utf8)) as? [String: Any]
        )
        let locations = try #require(json["locations"] as? [String: Any])

        #expect(json["href"] as? String == "chapter1.xhtml")
        #expect(locations["totalProgression"] as? Double == 0.0174)
        #expect(locations["cfi"] as? String == "epubcfi(/6/4[chap01]!/4/2/2)")
        #expect(locations["fragments"] as? [String] == ["par36"])
        #expect((json["text"] as? [String: Any])?["highlight"] as? String == "It was expected")
    }

    @Test func aPageReferenceBecomesAZeroBasedPDFLocatorOnAPDF() {
        let locator = OPDSProgressionMapping.ebookLocator(
            for: Self.book(format: "pdf"),
            point: OPDSProgressionPoint(pdfPage: 6),
            progression: 0.5
        )

        #expect(ReaderLocatorProgress.parsePDFLocator(locator) == 5)
    }

    @Test func aPageReferenceIsIgnoredWhenTheBookIsNotAPDF() {
        #expect(
            OPDSProgressionMapping.ebookLocator(
                for: Self.book(format: "epub"),
                point: OPDSProgressionPoint(pdfPage: 6),
                progression: 0.5
            ) == nil
        )
    }

    @Test func aProgressionWithNoUsableReferenceLeavesTheLocatorAlone() {
        #expect(
            OPDSProgressionMapping.ebookLocator(
                for: Self.book(format: "cbz"),
                point: OPDSProgressionPoint(additional: ["#vendorSpecific=1"]),
                progression: 0.4999
            ) == nil
        )
    }

    // MARK: Audio

    @Test func anAudioReferenceIsPreferredOverThePercentage() {
        #expect(
            OPDSProgressionMapping.audioSeconds(
                in: OPDSProgressionPoint(audioSeconds: 849.25),
                progression: 0.5,
                duration: 3600
            ) == 849.25
        )
    }

    @Test func anAudioReferencePastTheEndIsClampedToTheBook() {
        #expect(
            OPDSProgressionMapping.audioSeconds(
                in: OPDSProgressionPoint(audioSeconds: 99_999),
                progression: 1,
                duration: 3600
            ) == 3600
        )
    }

    @Test func aProgressionWithNoAudioReferenceFallsBackToThePercentage() {
        #expect(
            OPDSProgressionMapping.audioSeconds(
                in: OPDSProgressionPoint(resourcePath: "narrated.m4b"),
                progression: 0.25,
                duration: 3600
            ) == 900
        )
    }

    @Test func aPercentageWithNoDurationCannotBecomeATimeAtAll() {
        #expect(
            OPDSProgressionMapping.audioSeconds(
                in: OPDSProgressionPoint(),
                progression: 0.25,
                duration: nil
            ) == nil
        )
    }

    /// The draft expresses a position as a fraction of the publication, so a duration Enve never learned
    /// leaves it with nothing to send. A push that pretends otherwise records a write the service never saw.
    @Test func aPlaybackPositionWithNoDurationExpressesNoProgression() {
        #expect(OPDSProgressionMapping.audioProgression(seconds: 900, duration: nil) == nil)
        #expect(OPDSProgressionMapping.audioProgression(seconds: 900, duration: 0) == nil)
        #expect(OPDSProgressionMapping.audioProgression(seconds: .infinity, duration: 3600) == nil)
    }

    @Test func aPlaybackPositionIsTheFractionOfTheDurationItReached() {
        #expect(OPDSProgressionMapping.audioProgression(seconds: 900, duration: 3600) == 0.25)
        #expect(OPDSProgressionMapping.audioProgression(seconds: -10, duration: 3600) == 0)
        // A position past the end is the end; a progression above 1 is not a position the draft allows.
        #expect(OPDSProgressionMapping.audioProgression(seconds: 7200, duration: 3600) == 1)
    }

    private static func book(format: String) -> Book {
        Book(
            id: "urn:book",
            title: "Fixture",
            mediaType: .ebook,
            ebookFormat: format,
            providerId: providerId,
            libraryId: OPDSProvider.rootLibraryId
        )
    }
}
