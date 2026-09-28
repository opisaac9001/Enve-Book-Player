import Foundation
import Testing

@testable import enve

struct MediaOverlayTimelineLocatorTests {
    private let timeline = MediaOverlayTimeline(clips: [
        AudioOverlayClip(fragmentId: "ch1-s0", textHref: "text/ch1.xhtml", audioSrc: "a.m4a", clipBegin: 0, clipEnd: 10),
        AudioOverlayClip(fragmentId: "ch1-s1", textHref: "text/ch1.xhtml", audioSrc: "a.m4a", clipBegin: 10, clipEnd: 20),
        AudioOverlayClip(fragmentId: "ch1-s2", textHref: "text/ch1.xhtml", audioSrc: "a.m4a", clipBegin: 20, clipEnd: 30),
    ])

    @Test func resolvesAFragmentLocator() throws {
        let json = ##"{"href":"text/ch1.xhtml","type":"application/xhtml+xml","locations":{"fragments":["ch1-s1"],"progression":0.9}}"##
        let resolved = try #require(timeline.resolveEPUB3Locator(locatorJSON: json))

        #expect(resolved.clipIndex == 1)
        #expect(resolved.source == .fragment)
    }

    @Test func generatedLocatorRestoresExactTimeWithinFragment() throws {
        let json = try #require(timeline.textLocatorJSONString(clipIndex: 1, audioTime: 14.25))

        let resolved = try #require(timeline.resolveEPUB3Locator(locatorJSON: json))

        #expect(resolved.clipIndex == 1)
        #expect(resolved.audioTime == 14.25)
        #expect(resolved.source == .fragment)
    }

    @Test func resolvesTheAndroidDomRangeSentenceAnchor() throws {
        let json = ##"{"href":"text/ch1.xhtml","type":"application/xhtml+xml","locations":{"progression":0.9,"cssSelector":"body > section > p:nth-of-type(4)","domRange":{"start":{"cssSelector":"#ch1-s2","textNodeIndex":0,"charOffset":0},"end":{"cssSelector":"#ch1-s2","textNodeIndex":0,"charOffset":40}}}}"##
        let resolved = try #require(timeline.resolveEPUB3Locator(locatorJSON: json))

        #expect(resolved.clipIndex == 2)
        #expect(resolved.source == .fragment)
    }

    @Test func ignoresStructuralDomRangeSelectors() throws {
        let json = ##"{"href":"text/ch1.xhtml","type":"application/xhtml+xml","locations":{"progression":0.0,"domRange":{"start":{"cssSelector":"body > p:nth-of-type(2)","textNodeIndex":0,"charOffset":0}}}}"##
        let resolved = try #require(timeline.resolveEPUB3Locator(locatorJSON: json))

        #expect(resolved.source == .progression)
    }
}
