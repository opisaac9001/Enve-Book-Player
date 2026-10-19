import Foundation
import Testing

@testable import enve

@Suite @MainActor
struct EPUB3SMILOrderingTests {
    private typealias Document = EPUB3SMILParser.SMILDocument
    private typealias Entry = EPUB3SMILParser.ReadingOrderEntry

    private static func clip(_ id: String, _ textHref: String, _ audio: String) -> AudioOverlayClip {
        AudioOverlayClip(fragmentId: id, textHref: textHref, audioSrc: audio, clipBegin: 0, clipEnd: 1)
    }

    private static let readingOrder = [
        Entry(href: "OEBPS/Text/ch10.xhtml", overlayHrefs: ["OEBPS/Smil/ch10.smil"]),
        Entry(href: "OEBPS/Text/Chapter%2011.xhtml", overlayHrefs: ["OEBPS/Smil/Chapter%2011.smil"]),
        Entry(href: "OEBPS/Text/ch12.xhtml", overlayHrefs: ["OEBPS/Smil/ch12.smil"]),
    ]

    private static let documents = [
        Document(href: "OEBPS/Smil/ch12.smil", clips: [Self.clip("c12", "OEBPS/Smil/../Text/ch12.xhtml", "12.mp3")]),
        Document(href: "OEBPS/Smil/ch10.smil", clips: [
            Self.clip("c10a", "OEBPS/Text/ch10.xhtml", "10.mp3"),
            Self.clip("c10b", "OEBPS/Text/ch10.xhtml", "10.mp3"),
        ]),
        Document(href: "OEBPS/Smil/Chapter 11.smil", clips: [Self.clip("c11", "OEBPS/Text/Chapter 11.xhtml", "11.mp3")]),
    ]

    @Test func percentEncodedAndRelativeHrefsSortBySpine() {
        let ordered = EPUB3SMILParser.orderClips(documents: Self.documents, readingOrder: Self.readingOrder)

        #expect(ordered.map(\.fragmentId) == ["c10a", "c10b", "c11", "c12"])
        #expect(ordered.map(\.textHref) == [
            "OEBPS/Text/ch10.xhtml", "OEBPS/Text/ch10.xhtml",
            "OEBPS/Text/Chapter%2011.xhtml", "OEBPS/Text/ch12.xhtml",
        ])
    }

    @Test func unmatchedClipsStayWithTheirSMILDocument() {
        let documents = [
            Document(href: "OEBPS/Smil/ch12.smil", clips: [Self.clip("c12", "OEBPS/Text/ch12.xhtml", "12.mp3")]),
            Document(href: "OEBPS/Smil/Chapter%2011.smil", clips: [Self.clip("c11", "Elsewhere/unknown.xhtml", "11.mp3")]),
            Document(href: "OEBPS/Smil/ch10.smil", clips: [Self.clip("c10", "OEBPS/Text/ch10.xhtml", "10.mp3")]),
        ]

        let ordered = EPUB3SMILParser.orderClips(documents: documents, readingOrder: Self.readingOrder)

        #expect(ordered.map(\.fragmentId) == ["c10", "c11", "c12"])
        #expect(ordered[1].textHref == "Elsewhere/unknown.xhtml")
    }

    @Test func orderingIsIndependentOfDocumentDiscoveryOrder() {
        let expected = EPUB3SMILParser.orderClips(documents: Self.documents, readingOrder: Self.readingOrder)
            .map(\.fragmentId)
        for permutation in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            let documents = permutation.map { Self.documents[$0] }
            for _ in 0..<5 {
                let ordered = EPUB3SMILParser.orderClips(documents: documents, readingOrder: Self.readingOrder)
                #expect(ordered.map(\.fragmentId) == expected)
            }
        }
    }

    @Test func suffixMatchingRespectsPathComponents() {
        let readingOrder = [
            Entry(href: "Text/11.xhtml", overlayHrefs: []),
            Entry(href: "Text/1.xhtml", overlayHrefs: []),
        ]
        let documents = [Document(href: "1.smil", clips: [Self.clip("one", "1.xhtml", "1.mp3")])]

        let ordered = EPUB3SMILParser.orderClips(documents: documents, readingOrder: readingOrder)

        #expect(ordered.first?.textHref == "Text/1.xhtml")
    }

    @Test func normalizedResourcePathDecodesAndResolvesDots() {
        #expect(EPUB3SMILParser.normalizedResourcePath("/OEBPS/Smil/../Text/Chapter%2011.xhtml#p1") == "OEBPS/Text/Chapter 11.xhtml")
        #expect(EPUB3SMILParser.normalizedResourcePath("./Text/ch1.xhtml") == "Text/ch1.xhtml")
    }
}
