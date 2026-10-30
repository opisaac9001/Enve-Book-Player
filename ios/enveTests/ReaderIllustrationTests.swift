import Foundation
import Testing
import UIKit

@testable import enve

@MainActor
struct ReaderIllustrationTests {
    private func resolved(_ src: String, in documentHref: String) -> String? {
        ReaderIllustrationReference.resolvedHref(src: src, documentHref: documentHref)
    }

    @Test func relativeSourcesResolveAgainstTheChapter() {
        #expect(resolved("images/map.png", in: "OEBPS/text/ch1.xhtml") == "OEBPS/text/images/map.png")
        #expect(resolved("../images/map.png", in: "OEBPS/text/ch1.xhtml") == "OEBPS/images/map.png")
        #expect(resolved("./map.png", in: "OEBPS/ch1.xhtml") == "OEBPS/map.png")
        #expect(resolved("map.png", in: "ch1.xhtml") == "map.png")
    }

    @Test func rootRelativeSourcesStartAtThePublicationRoot() {
        #expect(resolved("/images/map.png", in: "OEBPS/text/ch1.xhtml") == "images/map.png")
        #expect(resolved("map.png", in: "/OEBPS/ch1.xhtml") == "OEBPS/map.png")
    }

    @Test func fragmentsQueriesAndPercentEncodingAreNormalized() {
        #expect(resolved("map.png#view", in: "OEBPS/ch1.xhtml") == "OEBPS/map.png")
        #expect(resolved("map.png?cache=1", in: "OEBPS/ch1.xhtml") == "OEBPS/map.png")
        #expect(resolved("my%20map.png", in: "OEBPS/ch1.xhtml") == "OEBPS/my map.png")
        #expect(resolved("map.png", in: "OEBPS/ch%201.xhtml#top") == "OEBPS/map.png")
    }

    @Test func encodedDelimitersRemainPartOfArchivePaths() {
        #expect(resolved("map%23one.png", in: "OEBPS/part%231/chapter.xhtml") == "OEBPS/part#1/map#one.png")
        #expect(resolved("map%3Fone.png", in: "OEBPS/part%3F1/chapter.xhtml#top") == "OEBPS/part?1/map?one.png")
    }

    @Test func climbingAboveTheRootStopsAtTheRoot() {
        #expect(resolved("../../../map.png", in: "a/b.xhtml") == "map.png")
    }

    @Test func anythingOutsideThePublicationIsRefused() {
        #expect(resolved("http://example.com/map.png", in: "OEBPS/ch1.xhtml") == nil)
        #expect(resolved("https://example.com/map.png", in: "OEBPS/ch1.xhtml") == nil)
        #expect(resolved("data:image/png;base64,AAAA", in: "OEBPS/ch1.xhtml") == nil)
        #expect(resolved("blob:enve-foliate://runtime/abc", in: "OEBPS/ch1.xhtml") == nil)
        #expect(resolved("javascript:alert(1)", in: "OEBPS/ch1.xhtml") == nil)
        #expect(resolved("#", in: "OEBPS/ch1.xhtml") == nil)
        #expect(resolved("", in: "OEBPS/ch1.xhtml") == nil)
    }

    @Test func payloadBecomesAReference() {
        let payload: [String: Any] = [
            "src": "../images/map.png",
            "alt": NSNull(),
            "caption": "Map of the realm",
            "width": 320,
            "height": 240,
        ]

        let reference = ReaderIllustrationScript.reference(from: payload, documentHref: "OEBPS/text/ch1.xhtml")

        #expect(reference == ReaderIllustrationReference(href: "OEBPS/images/map.png", alt: nil, caption: "Map of the realm"))
    }

    @Test func extraPayloadKeysAreTolerated() {
        let payload: [String: Any] = [
            "src": "map.png",
            "documentHref": "OEBPS/ch1.xhtml",
            "alt": "A map",
            "caption": NSNull(),
            "width": 300.5,
            "height": 200,
        ]

        let reference = ReaderIllustrationScript.reference(from: payload, documentHref: "OEBPS/ch1.xhtml")

        #expect(reference?.href == "OEBPS/map.png")
        #expect(reference?.alt == "A map")
        #expect(reference?.caption == nil)
    }

    @Test func ornamentsAndMalformedPayloadsAreIgnored() {
        let tiny: [String: Any] = ["src": "rule.png", "alt": NSNull(), "caption": NSNull(), "width": 300, "height": 12]
        let missingSource: [String: Any] = ["alt": NSNull(), "caption": NSNull(), "width": 300, "height": 300]
        let wrongType: [String: Any] = ["src": "map.png", "alt": NSNull(), "caption": NSNull(), "width": "300", "height": 300]

        #expect(ReaderIllustrationScript.reference(from: tiny, documentHref: "ch1.xhtml") == nil)
        #expect(ReaderIllustrationScript.reference(from: missingSource, documentHref: "ch1.xhtml") == nil)
        #expect(ReaderIllustrationScript.reference(from: wrongType, documentHref: "ch1.xhtml") == nil)
        #expect(ReaderIllustrationScript.reference(from: NSNull(), documentHref: "ch1.xhtml") == nil)
        #expect(ReaderIllustrationScript.reference(from: nil, documentHref: "ch1.xhtml") == nil)
    }

    @Test func subtitlePrefersTheBookCaptionOverTheDescription() {
        let image = UIImage()
        #expect(ReaderIllustration(image: image, alt: "Alt", caption: "Caption", hasTransparency: false).subtitle == "Caption")
        #expect(ReaderIllustration(image: image, alt: "Alt", caption: nil, hasTransparency: false).subtitle == "Alt")
        #expect(ReaderIllustration(image: image, alt: nil, caption: nil, hasTransparency: false).subtitle == nil)
    }

    @Test func opaqueRasterDataDecodesWithoutTransparency() throws {
        let data = pngData(size: CGSize(width: 120, height: 80), opaque: true)

        let image = try #require(ReaderIllustrationDecoder.image(from: data))

        #expect(image.size == CGSize(width: 120, height: 80))
        #expect(!ReaderIllustrationDecoder.hasAlpha(image))
    }

    @Test func transparentLineArtIsRecognized() throws {
        let data = pngData(size: CGSize(width: 120, height: 80), opaque: false)

        let image = try #require(ReaderIllustrationDecoder.image(from: data))

        #expect(ReaderIllustrationDecoder.hasAlpha(image))
    }

    @Test func oversizedPlatesAreDownsampled() throws {
        let data = pngData(size: CGSize(width: 6000, height: 200), opaque: true)

        let image = try #require(ReaderIllustrationDecoder.image(from: data))

        #expect(max(image.size.width, image.size.height) <= CGFloat(ReaderIllustrationDecoder.maxPixelSize))
        #expect(image.size.width > image.size.height)
    }

    @Test func undecodableDataIsRefused() {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>"#.utf8)

        #expect(ReaderIllustrationDecoder.image(from: svg) == nil)
        #expect(ReaderIllustrationDecoder.image(from: Data("not an image".utf8)) == nil)
        #expect(ReaderIllustrationDecoder.image(from: Data()) == nil)
    }

    private func pngData(size: CGSize, opaque: Bool) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        }
    }
}
