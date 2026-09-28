import Foundation
import Testing

@testable import enve

struct ReadAloudLyricsTests {

    private static let chapter = """
        <?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>c10A</title></head>
        <body>
        <p><span id="c10A.xhtml-s2">La silueta tambaleante me hiela la sangre.</span></p>
        <p><span id="c10A.xhtml-s3">Pablo se tambalea dentro. </span><span id="c10A.xhtml-s4">Su piel tiene un tono gris&#225;ceo.</span></p>
        <p><span id="c10A.xhtml-s9">Mira a Pablo como si entrara un extra de <span class="cite">Callejeros</span>.</span></p>
        <img src="x.jpg" id="img1"/>
        </body></html>
        """

    private func clip(_ fragment: String, href: String = "OEBPS/c10A.xhtml", start: Double, end: Double) -> AudioOverlayClip {
        AudioOverlayClip(
            fragmentId: fragment,
            textHref: href,
            audioSrc: "OEBPS/Audio/00001.mp4",
            clipBegin: start,
            clipEnd: end,
            granularity: .unspecified,
            parentGroupIndex: nil,
            textFragment: nil,
            skippableRole: nil
        )
    }

    @Test func extractsTextForEveryElementCarryingAnIdentifier() {
        let texts = ReadAloudLyricsBuilder.elementTexts(inHTML: Self.chapter)

        #expect(texts["c10A.xhtml-s2"] == "La silueta tambaleante me hiela la sangre.")
        #expect(texts["c10A.xhtml-s4"] == "Su piel tiene un tono grisáceo.")
    }

    @Test func keepsNestedMarkupAsPlainTextInsideASentence() {
        let texts = ReadAloudLyricsBuilder.elementTexts(inHTML: Self.chapter)

        #expect(texts["c10A.xhtml-s9"] == "Mira a Pablo como si entrara un extra de Callejeros.")
    }

    @Test func buildsLinesOnlyForClipsBelongingToTheGivenResource() {
        let clips = [
            clip("c10A.xhtml-s2", start: 0, end: 2),
            clip("c10A.xhtml-s3", start: 2, end: 5),
            clip("other.xhtml-s0", href: "OEBPS/other.xhtml", start: 5, end: 7),
        ]

        let lines = ReadAloudLyricsBuilder.lines(for: clips, inHTML: Self.chapter, matching: "OEBPS/c10A.xhtml")

        #expect(lines.count == 2)
        #expect(lines.map(\.id) == ["c10A.xhtml-s2", "c10A.xhtml-s3"])
        #expect(lines.map(\.clipIndex) == [0, 1])
        #expect(lines.first?.start == 0)
        #expect(lines.last?.end == 5)
    }

    @Test func skipsClipsWithNoMatchingTextSoEmptyLinesNeverRender() {
        let clips = [
            clip("c10A.xhtml-s2", start: 0, end: 2),
            clip("c10A.xhtml-missing", start: 2, end: 4),
            clip("img1", start: 4, end: 6),
        ]

        let lines = ReadAloudLyricsBuilder.lines(for: clips, inHTML: Self.chapter, matching: "OEBPS/c10A.xhtml")

        #expect(lines.map(\.id) == ["c10A.xhtml-s2"])
    }

    @Test func matchesResourcesThatDifferOnlyByDirectoryPrefix() {
        let clips = [clip("c10A.xhtml-s2", href: "c10A.xhtml", start: 0, end: 2)]

        let lines = ReadAloudLyricsBuilder.lines(for: clips, inHTML: Self.chapter, matching: "OEBPS/c10A.xhtml")

        #expect(lines.count == 1)
    }
}
