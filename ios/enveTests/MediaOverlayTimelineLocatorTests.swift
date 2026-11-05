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

    @Test func namedAudioOffsetWinsOverTextAndSpokenFractions() throws {
        let timeline = gappedTimeline()
        let json = #"{"href":"second.mp3","type":"audio/mpeg","locations":{"fragments":["t=17.25"],"totalProgression":0.01}}"#
        let resolved = try #require(timeline.resolveEPUB3Locator(locatorJSON: json))
        #expect(resolved.clipIndex == 1)
        #expect(resolved.audioTime == 117.25)
        #expect(resolved.source == .fragment)
    }

    @Test func audioPercentageUsesWholeFileDurationsIncludingGaps() throws {
        let json = #"{"href":"audiobook://fixture","type":"audio","locations":{"totalProgression":0.6}}"#
        let resolved = try #require(gappedTimeline().resolveEPUB3Locator(locatorJSON: json))
        #expect(resolved.clipIndex == 1)
        #expect(resolved.audioTime == 120)
    }

    @Test func namedAudioProgressionStaysWithinItsFile() throws {
        let json = #"{"href":"second.mp3","type":"audio/mpeg","locations":{"progression":0.25,"totalProgression":0.01}}"#
        let resolved = try #require(gappedTimeline().resolveEPUB3Locator(locatorJSON: json))
        #expect(resolved.audioTime == 125)
    }

    @Test func duplicateAudioBasenamesRequireAnExactPath() throws {
        let timeline = gappedTimeline(first: "Audio/one/track.mp3", second: "Audio/two/track.mp3")
        let exact = #"{"href":"Audio/two/track.mp3","type":"audio/mpeg","locations":{"fragments":["t=17.25"],"totalProgression":0.01}}"#
        #expect(try #require(timeline.resolveEPUB3Locator(locatorJSON: exact)).audioTime == 117.25)
        let ambiguous = #"{"href":"track.mp3","type":"audio/mpeg","locations":{"fragments":["t=17.25"],"totalProgression":0.6}}"#
        #expect(try #require(timeline.resolveEPUB3Locator(locatorJSON: ambiguous)).audioTime == 120)
        let unresolved = #"{"href":"track.mp3","type":"audio/mpeg","locations":{"fragments":["t=17.25"]}}"#
        #expect(timeline.resolveEPUB3Locator(locatorJSON: unresolved) == nil)
    }

    @Test func invalidTimeFragmentsUseTheAudioPercentage() throws {
        for time in ["NaN", "Infinity", "-5"] {
            let json = #"{"href":"second.mp3","type":"audio/mpeg","locations":{"fragments":["t=\#(time)"],"totalProgression":0.6}}"#
            #expect(try #require(gappedTimeline().resolveEPUB3Locator(locatorJSON: json)).audioTime == 120)
        }
    }

    private func gappedTimeline(first: String = "Audio/first.mp3", second: String = "Audio/second.mp3") -> MediaOverlayTimeline {
        MediaOverlayTimeline(clips: [
            AudioOverlayClip(fragmentId: "first", textHref: "one.xhtml", audioSrc: first, clipBegin: 10, clipEnd: 20),
            AudioOverlayClip(fragmentId: "second", textHref: "two.xhtml", audioSrc: second, clipBegin: 10, clipEnd: 30),
        ], audioDurationsBySource: [first: 100, second: 100], clipTextProgressions: [0.2, 0.8])
    }
}
