import ReadiumShared
import Testing

@testable import enve

struct ReaderLocationControllerTests {
    @Test func overlayHrefMatchingHandlesRootsAndRelativeDirectories() {
        #expect(ReadAloudOverlayTransform.hrefMatches("/OPS/chapter.xhtml", "OPS/chapter.xhtml"))
        #expect(ReadAloudOverlayTransform.hrefMatches("text/chapter.xhtml", "OPS/text/chapter.xhtml"))
        #expect(ReadAloudOverlayTransform.hrefMatches("one/chapter.xhtml", "two/chapter.xhtml"))
        #expect(!ReadAloudOverlayTransform.hrefMatches("chapter-1.xhtml", "chapter-2.xhtml"))
    }

    @Test func bestOverlayClipPrefersTheMatchingDocument() {
        let clips = [
            clip(fragment: "paragraph", href: "chapter-1.xhtml"),
            clip(fragment: "paragraph", href: "chapter-2.xhtml"),
        ]

        #expect(
            ReadAloudOverlayTransform.bestClipIndex(
                in: clips,
                fragmentId: "paragraph",
                preferredHref: "/OPS/chapter-2.xhtml"
            ) == 1
        )
    }

    @Test func stripsOnlyCFIFragmentsFromLocator() throws {
        let locator = try Locator(
            jsonString: """
                {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"fragments":["epubcfi(/6/2!/4)","paragraph-3"],"progression":0.2}}
                """
        )

        let stripped = ReaderLocationController.strippingCFIFragments(locator)

        #expect(stripped.locations.fragments == ["paragraph-3"])
        #expect(stripped.locations.progression == 0.2)
    }

    @Test func locationDifferenceUsesProgressionTolerance() throws {
        let initial = try locator(href: "chapter%201.xhtml", progression: 0.4)
        let equivalent = try locator(href: "chapter%201.xhtml", progression: 0.401)
        let moved = try locator(href: "chapter%201.xhtml", progression: 0.41)

        #expect(!ReaderLocationController.locationsDiffer(initial, equivalent))
        #expect(ReaderLocationController.locationsDiffer(initial, moved))
        #expect(ReaderLocationController.normalizedHref("chapter%201.xhtml#paragraph") == "chapter 1.xhtml")
    }

    @Test func retargetsLocatorToPublicationResourceWithoutChangingOtherFields() throws {
        let original = """
            {"href":"text/chapter.xhtml","type":"application/xhtml+xml","locations":{"progression":0.3}}
            """
        let retargeted = ReaderLocationController.retargetingHref(
            original,
            candidateHrefs: ["OPS/text/chapter.xhtml"]
        )
        let locator = try Locator(jsonString: retargeted)

        #expect(locator.href.string == "OPS/text/chapter.xhtml")
        #expect(locator.locations.progression == 0.3)
    }

    private func clip(fragment: String, href: String) -> AudioOverlayClip {
        AudioOverlayClip(
            fragmentId: fragment,
            textHref: href,
            audioSrc: "audio.mp3",
            clipBegin: 0,
            clipEnd: 1
        )
    }

    private func locator(href: String, progression: Double) throws -> Locator {
        try Locator(
            jsonString: """
                {"href":"\(href)","type":"application/xhtml+xml","locations":{"progression":\(progression)}}
                """
        )
    }
}
