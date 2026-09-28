import Foundation
import Testing

@testable import enve

struct MediaOverlayTextProgressionTests {
    private let chapterOne = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ignored title</title><style>p { margin: 0; }</style></head>
        <body>
          <h1 id="c1h">Start</h1>
          <p><span id="c1s1">Aaaa aaaa.</span> <span id="c1s2">Bbbb &amp; bbbb.</span></p>
          <!-- a comment <span id="ghost">x</span> -->
          <script>var x = "<span id='fake'>";</script>
          <p class="x" data-id="nope" id="c1s3">Cccc cccc cccc.</p>
        </body></html>
        """

    private let chapterTwo = #"<html><body><p id="c2s1">One.</p><p id="c2s2">Two.</p></body></html>"#

    private var chapters: [MediaOverlayTextProgression.ChapterText] {
        [
            .init(href: "OEBPS/text/cover.xhtml", start: 0, end: 0.1, xhtml: nil),
            .init(href: "OEBPS/text/ch1.xhtml", start: 0.1, end: 0.5, xhtml: chapterOne),
            .init(href: "OEBPS/text/ch2.xhtml", start: 0.5, end: 1.0, xhtml: chapterTwo),
        ]
    }

    private let clips = [
        AudioOverlayClip(fragmentId: "c1s1", textHref: "text/ch1.xhtml", audioSrc: "a.mp3", clipBegin: 0, clipEnd: 10),
        AudioOverlayClip(fragmentId: "c1s2", textHref: "text/ch1.xhtml", audioSrc: "a.mp3", clipBegin: 10, clipEnd: 20),
        AudioOverlayClip(fragmentId: "c1s3", textHref: "text/ch1.xhtml", audioSrc: "a.mp3", clipBegin: 20, clipEnd: 30),
        AudioOverlayClip(fragmentId: "c2s1", textHref: "text/ch2.xhtml", audioSrc: "b.mp3", clipBegin: 0, clipEnd: 100),
        AudioOverlayClip(fragmentId: "missing", textHref: "text/ch2.xhtml", audioSrc: "b.mp3", clipBegin: 100, clipEnd: 200),
        AudioOverlayClip(fragmentId: "c2s2", textHref: "text/ch2.xhtml", audioSrc: "b.mp3", clipBegin: 200, clipEnd: 300),
    ]

    @Test func countsRenderedBodyTextAndSkipsMarkupCommentsAndScripts() {
        let offsets = MediaOverlayTextProgression.fragmentOffsets(in: chapterOne)

        #expect(offsets.textLength == 45)
        #expect(offsets.offsetsById == ["c1h": 0, "c1s1": 6, "c1s2": 17, "c1s3": 30])
    }

    @Test func countsMultibyteCharactersOnceAndReadsSingleQuotedIds() {
        let offsets = MediaOverlayTextProgression.fragmentOffsets(in: "<body><p id='a'>héllo</p><p id='b'>x</p></body>")

        #expect(offsets.textLength == 6)
        #expect(offsets.offsetsById == ["a": 0, "b": 5])
    }

    @Test func placesFragmentsOnTheReadiumPositionScale() {
        let progressions = MediaOverlayTextProgression.clipProgressions(for: clips, chapters: chapters)

        #expect(progressions.count == clips.count)
        #expect(abs(progressions[0] - (0.1 + 6.0 / 45.0 * 0.4)) < 1e-9)
        #expect(abs(progressions[1] - (0.1 + 17.0 / 45.0 * 0.4)) < 1e-9)
        #expect(abs(progressions[2] - (0.1 + 30.0 / 45.0 * 0.4)) < 1e-9)
        #expect(abs(progressions[3] - 0.5) < 1e-9)
        #expect(abs(progressions[5] - 0.75) < 1e-9)
    }

    @Test func fallsBackToClipIndexRatioForAnUnknownFragment() {
        let progressions = MediaOverlayTextProgression.clipProgressions(for: clips, chapters: chapters)

        #expect(abs(progressions[4] - (0.5 + 1.0 / 3.0 * 0.5)) < 1e-9)
    }

    @Test func fallsBackToClipIndexRatioWhenChapterTextIsUnavailable() {
        let unreadable = chapters.map { MediaOverlayTextProgression.ChapterText(href: $0.href, start: $0.start, end: $0.end, xhtml: nil) }
        let progressions = MediaOverlayTextProgression.clipProgressions(for: clips, chapters: unreadable)

        #expect(abs(progressions[0] - 0.1) < 1e-9)
        #expect(abs(progressions[2] - (0.1 + 2.0 / 3.0 * 0.4)) < 1e-9)
    }

    @Test func narratedLocatorCarriesTheTextProgressionAndKeepsTheSentenceFragment() throws {
        let progressions = MediaOverlayTextProgression.clipProgressions(for: clips, chapters: chapters)
        let timeline = MediaOverlayTimeline(clips: clips, clipTextProgressions: progressions)
        let audioTime = try #require(timeline.audioTime(forClipIndex: 4)) + 50

        #expect(abs(timeline.readingProgression(atAudioTime: audioTime) - progressions[4]) < 1e-9)
        #expect(timeline.spokenProgression(atAudioTime: audioTime) > 0.5)

        let json = try #require(timeline.textLocatorJSONString(clipIndex: 1, audioTime: 15))
        let locator = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let locations = try #require(locator["locations"] as? [String: Any])
        #expect(locations["fragments"] as? [String] == ["c1s2", "t=15.0"])
        #expect(abs((locations["totalProgression"] as? Double ?? -1) - progressions[1]) < 1e-9)
    }

    @Test func resolvesAProgressionOnlyLocatorOnTheTextScale() throws {
        let progressions = MediaOverlayTextProgression.clipProgressions(for: clips, chapters: chapters)
        let timeline = MediaOverlayTimeline(clips: clips, clipTextProgressions: progressions)
        let json = #"{"href":"unknown.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.6}}"#

        let resolved = try #require(timeline.resolveEPUB3Locator(locatorJSON: json))

        #expect(resolved.clipIndex == 3)
    }

    @Test func completedNarrationFinishesTheBookDespiteUnnarratedBackMatter() {
        let progressions = MediaOverlayTextProgression.clipProgressions(for: clips, chapters: chapters)
        let timeline = MediaOverlayTimeline(clips: clips, orderedAudioDurations: [30, 300], clipTextProgressions: progressions)

        #expect(timeline.readingProgression(atAudioTime: timeline.totalAudioDuration) == 1)
        #expect(timeline.readingProgression(atAudioTime: timeline.totalAudioDuration - 50) < 1)
    }

    @Test func keepsTheSpokenScaleWhenTextProgressionsAreUnavailable() {
        let timeline = MediaOverlayTimeline(clips: clips)

        #expect(timeline.readingProgression(atAudioTime: 15) == timeline.spokenProgression(atAudioTime: 15))
    }
}
