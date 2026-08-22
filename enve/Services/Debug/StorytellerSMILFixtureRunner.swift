#if DEBUG && os(iOS)
import Foundation

struct StorytellerSMILFixtureResult: Sendable {
    let name: String
    let expected: String
    let actual: String
    let passed: Bool
}

enum StorytellerSMILFixtureRunner {
    static func run() -> [StorytellerSMILFixtureResult] {
        let audioA = "Audio/a.m4b"
        let audioB = "Audio/b.m4b"
        let clips = [
            AudioOverlayClip(
                fragmentId: "a1",
                textHref: "Text/ch1.xhtml",
                audioSrc: audioA,
                clipBegin: 2,
                clipEnd: 5
            ),
            AudioOverlayClip(
                fragmentId: "a2",
                textHref: "Text/ch1.xhtml",
                audioSrc: audioA,
                clipBegin: 8,
                clipEnd: 10
            ),
            AudioOverlayClip(
                fragmentId: "shared",
                textHref: "Text/ch1.xhtml",
                audioSrc: audioA,
                clipBegin: 12,
                clipEnd: 16
            ),
            AudioOverlayClip(
                fragmentId: "shared",
                textHref: "Text/ch2.xhtml",
                audioSrc: audioB,
                clipBegin: 1,
                clipEnd: 4
            ),
            AudioOverlayClip(
                fragmentId: "b2",
                textHref: "Text/ch2.xhtml",
                audioSrc: audioB,
                clipBegin: 7,
                clipEnd: 10
            ),
        ]
        let timeline = MediaOverlayTimeline(
            clips: clips,
            audioDurationsBySource: [audioA: 20, audioB: 15]
        )

        var results: [StorytellerSMILFixtureResult] = []

        results.append(
            expectTime(
                "B second clip uses the real cross-file clock",
                timeline.audioTime(forClipIndex: 4),
                27
            )
        )

        let gapExpectations: [(TimeInterval, String)] = [
            (0.5, "a1@ch1.xhtml"),
            (6, "a2@ch1.xhtml"),
            (8, "a2@ch1.xhtml"),
            (18, "shared@ch1.xhtml"),
            (20.5, "shared@ch1.xhtml"),
            (21, "shared@ch2.xhtml"),
            (25, "b2@ch2.xhtml"),
            (27, "b2@ch2.xhtml"),
            (34, "b2@ch2.xhtml"),
        ]
        for (time, expected) in gapExpectations {
            results.append(
                expect(
                    "Silence at \(time) seconds follows the Silveran text anchor",
                    clipLabel(timeline.clipIndex(atAudioTime: time), in: timeline),
                    expected
                )
            )
        }

        results.append(
            expect(
                "Duplicate fragment IDs are disambiguated by XHTML href",
                clipLabel(
                    timeline.clipIndex(fragmentId: "shared", preferredHref: "OPS/Text/ch2.xhtml"),
                    in: timeline
                ),
                "shared@ch2.xhtml"
            )
        )

        let mixedLocator = locatorJSON(
            href: "Text/ch2.xhtml",
            type: "application/xhtml+xml",
            fragments: ["t=3", "shared"],
            progression: 0.05,
            totalProgression: 0.1
        )
        let exactResolution = timeline.resolveEPUB3Locator(locatorJSON: mixedLocator)
        results.append(
            expect(
                "Exact XHTML anchor wins over stale audio time and progression",
                clipLabel(exactResolution?.clipIndex, in: timeline),
                "shared@ch2.xhtml"
            )
        )
        results.append(
            expectTime(
                "Exact XHTML anchor restores its clip start",
                exactResolution?.audioTime,
                21
            )
        )

        let trackATime = timeline.resolveEPUB3Locator(
            locatorJSON: locatorJSON(
                href: audioA,
                type: "audio",
                fragments: ["t=3"],
                progression: 0.9,
                totalProgression: 0.9
            )
        )
        let trackBTime = timeline.resolveEPUB3Locator(
            locatorJSON: locatorJSON(
                href: audioB,
                type: "audio",
                fragments: ["t=3"],
                progression: 0.1,
                totalProgression: 0.1
            )
        )
        results.append(
            expectTime(
                "Storyteller audio href and t never override its 90% book fraction",
                trackATime?.audioTime,
                27
            )
        )
        results.append(
            expectTime(
                "Storyteller audio href and t never override its 10% book fraction",
                trackBTime?.audioTime,
                2
            )
        )

        let externalAudio = timeline.resolveEPUB3Locator(
            locatorJSON: locatorJSON(
                href: "https://storyteller.example/audio/manifest.m4b",
                type: "audio/mp4",
                fragments: [],
                progression: 0,
                totalProgression: 27.0 / 35.0
            )
        )
        results.append(
            expectTime(
                "External audio locator uses the SMIL book clock",
                externalAudio?.audioTime,
                21
            )
        )

        let textFragment = TextFragment.parse("prefix-,Hello%2C%20world,-suffix")
        results.append(
            expect(
                "Text fragments preserve encoded punctuation",
                textFragment?.textStart ?? "nil",
                "Hello, world"
            )
        )

        let trackBGap = timeline.resolveEPUB3Locator(
            locatorJSON: locatorJSON(
                href: audioB,
                type: "audio",
                fragments: ["t=5"],
                progression: 0,
                totalProgression: 0
            )
        )
        results.append(expectTime("A zero book fraction starts at the first SMIL clip", trackBGap?.audioTime, 2))
        results.append(
            expect(
                "Track-local time is ignored for EPUB3 restoration",
                clipLabel(trackBGap?.clipIndex, in: timeline),
                "a1@ch1.xhtml"
            )
        )

        let incompleteAudioLocator = timeline.resolveEPUB3Locator(
            locatorJSON: locatorJSON(
                href: audioB,
                type: "audio",
                fragments: ["t=5"],
                progression: 0.5,
                totalProgression: nil
            )
        )
        results.append(
            expectTime(
                "Audio locator without book progression starts at the first SMIL entry",
                incompleteAudioLocator?.audioTime,
                2
            )
        )

        let sectionProgress = timeline.resolveEPUB3Locator(
            locatorJSON: locatorJSON(
                href: "Text/ch2.xhtml",
                type: "application/xhtml+xml",
                fragments: [],
                progression: 0.75,
                totalProgression: 0.05
            )
        )
        results.append(
            expect(
                "XHTML section progression wins over stale book progression",
                clipLabel(sectionProgress?.clipIndex, in: timeline),
                "b2@ch2.xhtml"
            )
        )

        let durationWeightedSectionProgress = timeline.resolveEPUB3Locator(
            locatorJSON: locatorJSON(
                href: "Text/ch1.xhtml",
                type: "application/xhtml+xml",
                fragments: [],
                progression: 0.6,
                totalProgression: 0.05
            )
        )
        results.append(
            expect(
                "Section progression uses Silveran SMIL duration weighting",
                clipLabel(durationWeightedSectionProgress?.clipIndex, in: timeline),
                "shared@ch1.xhtml"
            )
        )

        let incompleteTextData = try! JSONSerialization.data(withJSONObject: [
            "href": "Text/ch2.xhtml",
            "type": "application/xhtml+xml",
            "locations": [:],
        ])
        let incompleteText = timeline.resolveEPUB3Locator(
            locatorJSON: String(decoding: incompleteTextData, as: UTF8.self)
        )
        results.append(
            expect(
                "EPUB3 restoration has no separate percentage fallback",
                clipLabel(incompleteText?.clipIndex, in: timeline),
                "nil"
            )
        )

        let b2TextLocator = locatorJSON(
            href: "Text/ch2.xhtml",
            type: "application/xhtml+xml",
            fragments: ["b2"],
            progression: 0,
            totalProgression: 0
        )
        let b2AudioTime = timeline.resolveEPUB3Locator(locatorJSON: b2TextLocator)?.audioTime
        let returnedClipIndex = b2AudioTime.flatMap(timeline.clipIndex(atAudioTime:))
        let returnedTextLocator = returnedClipIndex.flatMap { clipIndex in
            b2AudioTime.flatMap {
                timeline.textLocatorJSONString(clipIndex: clipIndex, audioTime: $0)
            }
        }
        let returnedText = returnedTextLocator.flatMap(parseLocator)
        let returnedLocations = returnedText?["locations"] as? [String: Any]
        let returnedFragments = returnedLocations?["fragments"] as? [String] ?? []
        results.append(expectTime("Text b2 maps to global audio time", b2AudioTime, 27))
        results.append(
            expect(
                "Audio round-trip returns to text b2",
                returnedFragments.first ?? "nil",
                "b2"
            )
        )
        results.append(
            expect(
                "Generated text locator is XHTML",
                returnedText?["type"] as? String ?? "nil",
                "application/xhtml+xml"
            )
        )
        results.append(
            expect(
                "Generated XHTML locator contains no audio t fragment",
                returnedFragments.contains(where: { $0.hasPrefix("t=") }) ? "contains t" : "no t",
                "no t"
            )
        )

        return results
    }

    private static func expect(_ name: String, _ actual: String, _ expected: String) -> StorytellerSMILFixtureResult {
        StorytellerSMILFixtureResult(
            name: name,
            expected: expected,
            actual: actual,
            passed: actual == expected
        )
    }

    private static func expectTime(
        _ name: String,
        _ actual: TimeInterval?,
        _ expected: TimeInterval
    ) -> StorytellerSMILFixtureResult {
        let passed = actual.map { abs($0 - expected) < 0.000_001 } ?? false
        return StorytellerSMILFixtureResult(
            name: name,
            expected: format(expected),
            actual: actual.map(format) ?? "nil",
            passed: passed
        )
    }

    private static func clipLabel(_ index: Int?, in timeline: MediaOverlayTimeline) -> String {
        guard let index, timeline.clips.indices.contains(index) else { return "nil" }
        let clip = timeline.clips[index]
        return "\(clip.fragmentId)@\((clip.textHref as NSString).lastPathComponent)"
    }

    private static func locatorJSON(
        href: String,
        type: String,
        fragments: [String],
        progression: Double,
        totalProgression: Double?
    ) -> String {
        var locations: [String: Any] = [
            "fragments": fragments,
            "progression": progression,
        ]
        if let totalProgression {
            locations["totalProgression"] = totalProgression
        }
        let locator: [String: Any] = [
            "href": href,
            "type": type,
            "locations": locations,
        ]
        let data = try! JSONSerialization.data(withJSONObject: locator)
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseLocator(_ value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func format(_ value: TimeInterval) -> String {
        String(format: "%.9f", value)
    }
}
#endif
