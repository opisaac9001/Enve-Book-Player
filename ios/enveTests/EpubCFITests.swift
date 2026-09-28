import Foundation
import Testing

@testable import enve

struct EpubCFITests {
    private static let chapter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ignored</title></head>
        <body>
          <section id="ch1">
            <h1>Chapter <em>One</em></h1>
            <p id="p1"><span id="s1">First sentence.</span> <span id="s2">Second <i>nested</i> sentence here.</span></p>
            <p>Caf&#233; \u{1F600} text with <b>bold</b> and more words after the bold part.<!-- split -->Tail run.</p>
            <p id="dup">Duplicate A</p>
            <p id="dup">Duplicate B</p>
          </section>
        </body></html>
        """

    private static let package = EpubPackage(
        spineStep: 6,
        spine: [
            .init(itemrefID: nil, href: "OEBPS/text/cover.xhtml", mediaOverlayHref: nil, isLinear: false),
            .init(itemrefID: "c1", href: "OEBPS/text/ch1.xhtml", mediaOverlayHref: "OEBPS/smil/ch1.smil", isLinear: true),
        ]
    )

    private func document(_ html: String = chapter) throws -> EpubXHTMLDocument {
        let document = EpubXHTMLDocument()
        try document.parse(html: html)
        return document
    }

    private func cfi(for locator: [String: Any], in document: EpubXHTMLDocument) -> String? {
        guard let point = EpubCFI.point(forLocator: locator, in: document) else { return nil }
        return EpubCFI.verifiedCFI(to: point, in: document, spineIndex: 1, package: Self.package)
    }

    @Test func narratedSentenceBecomesAnElementCFIWithIdAssertions() throws {
        let document = try document()
        let locator: [String: Any] = [
            "href": "OEBPS/text/ch1.xhtml",
            "locations": ["fragments": ["s2"], "progression": 0.3, "totalProgression": 0.4],
        ]

        #expect(cfi(for: locator, in: document) == "epubcfi(/6/4[c1]!/4/2[ch1]/4[p1]/4[s2])")
    }

    @Test func textQuoteBecomesATextOffsetCountedInUTF16() throws {
        let document = try document()
        let afterBold: [String: Any] = [
            "href": "OEBPS/text/ch1.xhtml",
            "locations": ["progression": 0.5],
            "text": ["highlight": "and more words after the bold part.", "before": "with bold"],
        ]
        let afterEmoji: [String: Any] = [
            "href": "OEBPS/text/ch1.xhtml",
            "locations": ["progression": 0.5],
            "text": ["highlight": "text   with bold and more"],
        ]

        #expect(cfi(for: afterBold, in: document) == "epubcfi(/6/4[c1]!/4/2[ch1]/6/3:1)")
        // "Café " is five units and the emoji two, then the space.
        #expect(cfi(for: afterEmoji, in: document) == "epubcfi(/6/4[c1]!/4/2[ch1]/6/1:8)")
    }

    @Test func textSplitByACommentStaysOneChunk() throws {
        let document = try document()
        let tail: [String: Any] = ["text": ["highlight": "Tail run."], "locations": [:]]

        #expect(cfi(for: tail, in: document) == "epubcfi(/6/4[c1]!/4/2[ch1]/6/3:36)")
    }

    @Test func progressionLandsOnTheCharacterAtThatFraction() throws {
        let document = try document()
        let index = document.textIndex()
        let point = try #require(index.point(atFraction: 0))
        let path = try #require(document.localPath(to: point))

        #expect(path == "/4/2[ch1]/2/1:0")
        #expect(index.offset(of: point) > 0)
    }

    @Test func builtCFIsResolveToTheSameElementOrText() throws {
        let document = try document()
        let index = document.textIndex()
        var points: [EpubCFI.Point] = []
        for id in ["ch1", "p1", "s1", "s2"] {
            points.append(EpubCFI.Point(element: try #require(document.element(withID: id)), text: nil))
        }
        for offset in stride(from: 0, to: index.length, by: 7) {
            points.append(try #require(index.point(atOffset: offset)))
        }

        for point in points {
            let cfi = try #require(EpubCFI.verifiedCFI(to: point, in: document, spineIndex: 1, package: Self.package))
            let parsed = try #require(EpubCFI.parse(cfi))
            let resolved = try #require(document.resolve(parsed.local))
            #expect(resolved.isSameLocation(as: point))
            #expect(EpubCFI.spineIndex(of: parsed, in: Self.package) == 1)
        }
    }

    @Test func duplicateIdsFailTheRoundTrip() throws {
        let document = try document()
        let second: [String: Any] = [
            "href": "OEBPS/text/ch1.xhtml",
            "locations": ["cfi": "epubcfi(/6/4!/4/2/10[dup])", "enveSourceEngine": "foliate"],
        ]
        let first: [String: Any] = [
            "href": "OEBPS/text/ch1.xhtml",
            "locations": ["cfi": "epubcfi(/6/4!/4/2/8[dup])", "enveSourceEngine": "foliate"],
        ]

        #expect(cfi(for: second, in: document) == nil)
        #expect(cfi(for: first, in: document) == "epubcfi(/6/4[c1]!/4/2[ch1]/8[dup])")
    }

    @Test func malformedXHTMLNeverProducesACFI() throws {
        let document = try document("<html><body><p id=\"a\">Open <b>never closed</p></body></html>")
        let locator: [String: Any] = ["locations": ["fragments": ["a"]]]

        #expect(!document.isWellFormed)
        #expect(cfi(for: locator, in: document) == nil)
    }

    @Test func parsesRangesEscapesAndIgnoresTextAssertions() throws {
        let range = try #require(EpubCFI.parse("epubcfi(/6/4[c1]!/4/2[ch1],/4[p1]/2[s1]/1:3,/6/1:9)"))
        #expect(range.package.map(\.index) == [6, 4])
        #expect(range.local.map(\.index) == [4, 2, 4, 2, 1])
        #expect(range.local.last?.offset == 3)

        let escaped = try #require(EpubCFI.parse("epubcfi(/6/4!/4/2[a^]b^,c;s=a]/3:5[yyy,zzz;s=b])"))
        #expect(escaped.local[1].assertion == "a]b,c")
        #expect(escaped.local[2].assertion == nil)
        #expect(escaped.local[2].offset == 5)
        #expect(EpubCFI.assertion("a]b,c") == "[a^]b^,c]")

        #expect(EpubCFI.parse("epubcfi(/6/4)") == nil)
        #expect(EpubCFI.parse("not a cfi") == nil)
    }

    @Test func resolvesToAReadiumLocatorWithTheNarratedFragment() throws {
        let document = try document()
        let narrated: Set<String> = ["s1", "s2"]
        func resolved(_ cfi: String) throws -> EpubCFI.Point {
            let parsed = try #require(EpubCFI.parse(cfi))
            return try #require(document.resolve(parsed.local))
        }
        let inNestedItalic = try resolved("epubcfi(/6/4!/4/2/4/4/2/1:2)")
        let paragraph = try resolved("epubcfi(/6/4!/4/2/4)")
        let unnarrated = try resolved("epubcfi(/6/4!/4/2/6/3:1)")

        let italic = EpubCFI.readiumLocator(
            at: inNestedItalic, in: document, href: "OEBPS/text/ch1.xhtml", totalProgression: 0.4, overlayFragments: narrated
        )
        let descendant = EpubCFI.readiumLocator(
            at: paragraph, in: document, href: "OEBPS/text/ch1.xhtml", totalProgression: 0.4, overlayFragments: narrated
        )
        let plain = EpubCFI.readiumLocator(
            at: unnarrated, in: document, href: "OEBPS/text/ch1.xhtml", totalProgression: 0.4, overlayFragments: narrated
        )

        #expect((italic["locations"] as? [String: Any])?["fragments"] as? [String] == ["s2"])
        #expect((descendant["locations"] as? [String: Any])?["fragments"] as? [String] == ["s1"])
        #expect((plain["locations"] as? [String: Any])?["fragments"] == nil)
        #expect(((plain["text"] as? [String: Any])?["highlight"] as? String)?.hasPrefix("and more words") == true)
        #expect((plain["locations"] as? [String: Any])?["totalProgression"] as? Double == 0.4)
        let progression = try #require((plain["locations"] as? [String: Any])?["progression"] as? Double)
        #expect(progression > 0.3 && progression < 0.9)
    }

    @Test func packageSpineKeepsNonLinearItemsAndResolvesHrefs() throws {
        let opf = """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata/>
              <manifest>
                <item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch" href="text/My%20Chapter.xhtml" media-overlay="ch-smil" media-type="application/xhtml+xml"/>
                <item id="ch-smil" href="../smil/ch.smil" media-type="application/smil+xml"/>
              </manifest>
              <spine>
                <itemref idref="cover" linear="no"/>
                <itemref id="ref-ch" idref="ch"/>
              </spine>
            </package>
            """
        let package = EpubPackage(opfData: Data(opf.utf8), opfPath: "OEBPS/content.opf")

        #expect(package.spineStep == 6)
        #expect(package.spine.map(\.href) == ["OEBPS/text/cover.xhtml", "OEBPS/text/My Chapter.xhtml"])
        #expect(package.spine.map(\.isLinear) == [false, true])
        #expect(package.spine[1].itemrefID == "ref-ch")
        #expect(package.spine[1].mediaOverlayHref == "smil/ch.smil")
        #expect(package.spineIndex(forHref: "OEBPS/text/My%20Chapter.xhtml#s1") == 1)
        #expect(package.spineIndex(forHref: "text/cover.xhtml") == 0)
    }
}
