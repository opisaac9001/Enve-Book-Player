import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSProgressionReferenceTests {

    // MARK: Classification

    @Test func aPublicationLevelMediaFragmentIsAnAudioTime() {
        let reference = OPDSProgressionReference(raw: "#t=849.250")

        #expect(reference.path.isEmpty)
        #expect(reference.fragment == .mediaTime(849.25))
        #expect(reference.raw == "#t=849.250")
    }

    @Test(arguments: [
        ("#t=67", 67.0),
        ("#t=npt:10", 10.0),
        ("#t=00:03:00", 180.0),
        ("#t=npt:00:00:01.5", 1.5),
        ("#t=10,20", 10.0),
        ("#t=,20", 0.0),
    ])
    func normalPlayTimeIsResolvedToItsStartInSeconds(sample: (raw: String, seconds: Double)) {
        #expect(OPDSProgressionReference(raw: sample.raw).fragment == .mediaTime(sample.seconds))
    }

    @Test(arguments: [
        "#t=smpte-25:00:10:00", "#t=clock:2009-07-26T11:19:01Z", "#t=abc", "#t=1:2:3:4",
        "#page=0", "#page=", "#page=six", "#xywh=160,120,320,240",
    ])
    func aFragmentEnveCannotResolveStaysOpaqueAndKeepsItsText(raw: String) {
        #expect(OPDSProgressionReference(raw: raw).fragment == .opaque(String(raw.dropFirst())))
    }

    @Test(arguments: [("#page=87", 87), ("#nameddest=intro&page=6", 6), ("#page=6&zoom=100", 6)])
    func aPDFFragmentIsResolvedToItsOneBasedPage(sample: (raw: String, page: Int)) {
        #expect(OPDSProgressionReference(raw: sample.raw).fragment == .pdfPage(sample.page))
    }

    @Test func aResourcePathCarriesItsScrollToTextDirective() {
        let reference = OPDSProgressionReference(raw: "chapter1.html#:~:text=It%20was%20expected")

        #expect(reference.path == "chapter1.html")
        #expect(reference.fragment == .scrollToText("It%20was%20expected"))
    }

    @Test func aResourcePathCarriesItsElementIdentifier() {
        let reference = OPDSProgressionReference(raw: "chapter1.html#par36")

        #expect(reference.path == "chapter1.html")
        #expect(reference.fragment == .htmlID("par36"))
    }

    @Test func aPrePaginatedReferenceIsABareResourcePath() {
        let reference = OPDSProgressionReference(raw: "chapter5.html")

        #expect(reference.path == "chapter5.html")
        #expect(reference.fragment == nil)
    }

    @Test func anAbsoluteURLKeepsItsWholePathAndItsFragment() {
        let reference = OPDSProgressionReference(raw: "https://example.com/chapter1#:~:text=an%20example")

        #expect(reference.path == "https://example.com/chapter1")
        #expect(reference.fragment == .scrollToText("an%20example"))
    }

    @Test func aCFIFragmentIsUnwrapped() {
        let reference = OPDSProgressionReference(raw: "#epubcfi(/6/4[chap01]!/4/2/2)")

        #expect(reference.fragment == .epubCFI("/6/4[chap01]!/4/2/2"))
    }

    @Test(arguments: [
        ("an%20example", "an example"),
        ("prefix-,start", "start"),
        ("start,-suffix", "start"),
        ("prefix-,start,-suffix", "start"),
        ("start,end", "start"),
    ])
    func aTextDirectiveResolvesToItsStartTerm(sample: (directive: String, snippet: String)) {
        #expect(OPDSProgressionReference.textDirectiveSnippet(sample.directive) == sample.snippet)
    }

    @Test func directiveSyntaxIsPercentEncodedSoASnippetNeverSpellsIt() throws {
        let directive = try #require(OPDSProgressionReference.textDirective(forSnippet: "one, two & three-four"))

        #expect(!directive.contains(","))
        #expect(!directive.contains("&"))
        #expect(!directive.contains("-"))
        #expect(OPDSProgressionReference.textDirectiveSnippet(directive) == "one, two & three-four")
    }

    // MARK: Ordering

    @Test func referencesAreWrittenMostSpecificFirst() {
        let point = OPDSProgressionPoint(
            audioSeconds: 40.274,
            resourcePath: "chapter1.html",
            scrollToText: "It was expected",
            htmlID: "par36",
            pdfPage: 6,
            epubCFI: "/6/4[chap01]!/4/2/2",
            additional: ["#somethingElse=1"]
        )

        #expect(
            point.references == [
                "#t=40.274",
                "chapter1.html#:~:text=It%20was%20expected",
                "chapter1.html#par36",
                "#page=6",
                "#epubcfi(/6/4[chap01]!/4/2/2)",
                "#somethingElse=1",
            ]
        )
    }

    @Test func aResourcePathThatIsNotAURIReferenceIsEncodedBeforeItIsWritten() {
        let point = OPDSProgressionPoint(resourcePath: "chapter 1.xhtml", htmlID: "par36")

        #expect(point.references == ["chapter%201.xhtml#par36"])
    }

    @Test func aResourceWithNoFragmentIsWrittenBare() {
        let point = OPDSProgressionPoint(resourcePath: "chapter5.html")

        #expect(point.references == ["chapter5.html"])
    }

    @Test(arguments: [(67.0, "#t=67"), (100.0, "#t=100"), (849.25, "#t=849.25"), (0.0, "#t=0")])
    func aTimeIsWrittenWithoutTrailingZeros(sample: (seconds: Double, reference: String)) {
        #expect(OPDSProgressionPoint(audioSeconds: sample.seconds).references == [sample.reference])
    }

    // MARK: Losslessness

    @Test func everyResolvedFieldSurvivesAnEncodeAndDecode() {
        let point = OPDSProgressionPoint(
            audioSeconds: 40.274,
            resourcePath: "chapter1.html",
            scrollToText: "It was expected",
            htmlID: "par36",
            pdfPage: 6,
            epubCFI: "/6/4[chap01]!/4/2/2",
            additional: ["#somethingElse=1"]
        )

        #expect(OPDSProgressionPoint(references: point.references) == point)
    }

    @Test func aReferenceEnveCannotResolveIsCarriedThroughUntouched() {
        let references = ["#t=5", "#somethingElse=1", "spread.jxl#xywh=160,120,320,240"]

        let point = OPDSProgressionPoint(references: references)

        #expect(point.audioSeconds == 5)
        #expect(point.additional == ["#somethingElse=1", "spread.jxl#xywh=160,120,320,240"])
        #expect(point.references == references)
    }

    @Test func aSecondReferenceOfTheSameKindIsKeptRatherThanDiscarded() {
        let point = OPDSProgressionPoint(references: ["#t=5", "#t=9", "a.html", "b.html"])

        #expect(point.audioSeconds == 5)
        #expect(point.resourcePath == "a.html")
        #expect(point.additional == ["#t=9", "b.html"])
    }

    @Test func aFragmentWithNoResourceIsPreservedRatherThanAppliedToAnUnknownResource() {
        let point = OPDSProgressionPoint(references: ["#par36", "#:~:text=orphan"])

        #expect(point.htmlID == nil)
        #expect(point.scrollToText == nil)
        #expect(point.additional == ["#par36", "#:~:text=orphan"])
    }

    @Test func aTimeOnAResourceRecordsBothTheTimeAndTheResource() {
        let point = OPDSProgressionPoint(references: ["narrated.m4b#t=40"])

        #expect(point.audioSeconds == 40)
        #expect(point.resourcePath == "narrated.m4b")
        #expect(point.additional.isEmpty)
    }

    // MARK: Merging what the service sent back

    @Test func aRetainedReferenceOfAKindThePointRegeneratesIsNotWrittenTwice() {
        let point = OPDSProgressionPoint(audioSeconds: 120, additional: ["#t=9", "#somethingElse=1"])

        #expect(point.references == ["#t=120", "#somethingElse=1"])
    }

    @Test func aRetainedResourcePathGivesWayToTheOneTheReaderIsOn() {
        let point = OPDSProgressionPoint(resourcePath: "chapter2.html", additional: ["chapter1.html"])

        #expect(point.references == ["chapter2.html"])
    }

    @Test func anIdenticalRetainedReferenceIsOnlyWrittenOnce() {
        let point = OPDSProgressionPoint(additional: ["#vendor=1", "#vendor=1", "#vendor=2"])

        #expect(point.references == ["#vendor=1", "#vendor=2"])
    }

    @Test func aRetainedReferenceNothingRegeneratedIsStillWritten() {
        let point = OPDSProgressionPoint(audioSeconds: 12, additional: ["#page=4", "spread.jxl#xywh=1,2,3,4"])

        #expect(point.references == ["#t=12", "#page=4", "spread.jxl#xywh=1,2,3,4"])
    }

    @Test func draftExampleFourDecodesToItsTwoReferences() {
        let point = OPDSProgressionPoint(references: ["#t=40.274", "chapter1.html#par36"])

        #expect(point.audioSeconds == 40.274)
        #expect(point.resourcePath == "chapter1.html")
        #expect(point.htmlID == "par36")
        #expect(point.additional.isEmpty)
    }
}
