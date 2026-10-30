import Foundation

@main
struct TVReadAlongRegressionTests {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func clip(_ href: String, _ fragment: String, _ source: String, _ begin: Double, _ end: Double) -> TVAudioOverlayClip {
            TVAudioOverlayClip(fragmentId: fragment, textHref: href, audioSrc: source, clipBegin: begin, clipEnd: end, skippableRole: nil)
        }
        let clips = [
            clip("EPUB/Text/one.xhtml", "s1", "EPUB/Audio/one.m4a", 2, 7),
            clip("EPUB/Text/one.xhtml", "s2", "EPUB/Audio/one.m4a", 9, 14),
            clip("EPUB/Text/two.xhtml", "s1", "EPUB/Audio/two.m4a", 3, 13),
            clip("EPUB/Text/two.xhtml", "s2", "EPUB/Audio/two.m4a", 13, 18),
        ]
        let timeline = TVStorytellerTimeline(clips: clips)
        expect(timeline.duration == 25, "Narration duration excludes unmapped lead-in and silence")
        expect(timeline.starts == [0, 5, 10, 20], "Global timing spans audio files")
        expect(timeline.clipIndex(at: -10) == 0, "Rewind clamps to first passage")
        expect(timeline.clipIndex(at: 4.999) == 0, "A passage owns its half-open time range")
        expect(timeline.clipIndex(at: 5) == 1, "A passage boundary selects the following passage")
        expect(timeline.clipIndex(at: 10) == 2, "A chapter boundary selects the following chapter")
        expect(timeline.clipIndex(at: 25) == 3, "End of book selects the final passage")
        expect(timeline.clipIndex(at: 100) == 3, "Overshooting clamps to the final passage")
        expect(timeline.clipIndex(at: 4 + 15) == 2, "Forward skip carries its residual time across chapters")
        expect(timeline.clipIndex(at: 21 - 15) == 1, "Rewind carries its residual time across chapters")
        expect(timeline.groups.count == 2, "Consecutive passages share a continuous audio queue item")
        expect(timeline.groupIndices == [0, 0, 1, 1], "Each passage belongs to the correct audio file")
        expect(timeline.clipIndex(atAudioTime: 10, inGroup: 0) == 1, "A delayed callback catches up to actual audio time")
        expect(timeline.clipIndex(atAudioTime: 8, inGroup: 0) == 0, "A silent gap does not highlight the next passage early")
        expect(timeline.clipIndex(atAudioTime: 13, inGroup: 1) == 3, "Exact audio boundaries advance once")
        expect(timeline.clipIndex(atAudioTime: 12.99999, inGroup: 1) == 3, "Audio sample rounding cannot strand a paused seek on the previous passage")
        expect(timeline.elapsedTime(atAudioTime: 8, clipIndex: 0) == 5, "Narration clock holds during unmapped silence")
        expect(timeline.elapsedTime(atAudioTime: 8, clipIndex: 2) == 15, "Nonzero file starts map to book time")
        expect(clips[0].id != clips[2].id, "Repeated fragment IDs in different chapters remain distinct")
        let replay = TVStorytellerTimeline(clips: [clips[0], clip("one", "repeat", clips[0].audioSrc, 0, 2)])
        expect(replay.groups.count == 2, "Reused audio that jumps backwards gets a fresh queue item")
        expect(TVStorytellerTimeline(clips: []).clipIndex(at: 0) == nil, "An empty book has no passage")
        expect(TVStorytellerPaths.normalizeHref("/EPUB/Text/../Text/chapter%20one.xhtml") == "EPUB/Text/chapter one.xhtml", "Percent-encoded chapter paths are canonical")
        expect(TVStorytellerPaths.resolve("../Audio/voice%20one.m4a", relativeTo: "EPUB/Overlays/chapter.smil") == "EPUB/Audio/voice one.m4a", "SMIL paths resolve relative to the overlay")

        let smil = """
        <smil xmlns="http://www.w3.org/ns/SMIL"><body><seq epub:type="chapter" xmlns:epub="http://www.idpf.org/2007/ops">
          <par><text src="../Text/chapter%20one.xhtml#s%201"/><audio src="../Audio/voice%20one.m4a" clipBegin="npt=00:00:02.000" clipEnd="7000ms"/></par>
          <par><text src="../Text/chapter%20one.xhtml#s2"/><audio src="../Audio/voice%20one.m4a" clipBegin="9s" clipEnd="14s"/></par>
          <par><text src="../Text/chapter%20one.xhtml#bad"/><audio src="../Audio/voice%20one.m4a" clipBegin="-1" clipEnd="2"/></par>
          <par><text src="../Text/chapter%20one.xhtml#bad"/><audio src="../Audio/voice%20one.m4a" clipBegin="nan" clipEnd="inf"/></par>
          <par><text src="../Text/chapter%20one.xhtml#start"/><audio src="../Audio/voice%20one.m4a" clipEnd="1"/></par>
        </seq></body></smil>
        """
        let parsed = try TVSmilXMLParser(data: Data(smil.utf8), baseHref: "EPUB/Overlays/chapter.smil").parseAndReturn()
        expect(parsed.count == 3, "Malformed timing is rejected at the EPUB boundary")
        expect(parsed.last?.clipBegin == 0, "SMIL's omitted clipBegin starts at zero")
        expect(parsed.first?.fragmentId == "s 1", "Encoded fragment IDs are decoded")
        expect(parsed.first?.textHref == "EPUB/Text/chapter one.xhtml", "Clip text uses canonical EPUB-root-relative paths")
        expect(parsed.first?.audioSrc == "EPUB/Audio/voice one.m4a", "Clip audio retains its directory, avoiding flattened-filename collisions")
        expect(parsed.first?.clipBegin == 2 && parsed.first?.clipEnd == 7, "SMIL clock formats agree")
        expect(TVSmilXMLParser.parseSmilClock("1.5min") == 90, "Minute clocks are supported")
        expect(TVSmilXMLParser.parseSmilClock("01:02:03.5") == 3723.5, "Hour clocks are supported")
        for malformed in [String(smil.prefix(upTo: smil.range(of: "</seq>")!.lowerBound)), smil + "<extra>"] {
            do {
                _ = try TVSmilXMLParser(data: Data(malformed.utf8), baseHref: "chapter.smil").parseAndReturn()
                preconditionFailure("Malformed XML must never become a partial narration timeline")
            } catch TVSmilXMLParser.ParseError.malformedXML {
                checks += 1
            }
        }
        let empty = try TVSmilXMLParser(data: Data("<smil><body/></smil>".utf8), baseHref: "empty.smil").parseAndReturn()
        expect(empty.isEmpty, "Well-formed unaligned SMIL remains distinct from damaged XML")

        let package = TVStorytellerPackageParser()
        expect(package.parse(Data("""
        <package><manifest>
          <item href='Text/two.xhtml' media-overlay='smil2' id='two'/>
          <item id='one' media-overlay='smil1' href='Text/one.xhtml'/>
          <item id='smil1' href='Overlays/one.smil'/><item id='smil2' href='Overlays/two.smil'/>
        </manifest><spine><itemref idref='one'/><itemref idref='two'/></spine></package>
        """.utf8)), "Package XML supports legal single-quoted attributes")
        expect(package.spine == ["one", "two"], "Reading order comes from the spine rather than manifest or filesystem order")
        expect(package.items["one"]?.overlayID == "smil1", "Each spine item resolves its declared media overlay")
        let text = TVStorytellerTextParser(fragments: ["sentence-1", "sentence-2"], counterStart: 40)
        expect(text.parse("""
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fallback</title><style>hidden CSS</style></head><body>
        <h1 id="unrelated">The chapter</h1>
        <p id="paragraph"><span id="sentence-1">A <em>quiet</em> night &#8212; with &ldquo;stars&rdquo;.</span> <span id="sentence-2">The road &amp; the river.</span></p>
        <p>Context after the narration.</p><script>hidden script</script><p aria-hidden="true">Hidden duplicate.</p>
        </body></html>
        """), "Nested EPUB XHTML can be read")
        expect(text.title == "The chapter", "Chapter heading takes precedence over document title")
        expect(text.segments.map(\.text) == ["The chapter", "A quiet night — with “stars”.", "The road & the river.", "Context after the narration."], "Aligned text respects element boundaries and retains surrounding prose")
        expect(text.segments.map(\.fragmentId) == [nil, "sentence-1", "sentence-2", nil], "Only SMIL-referenced anchors own a passage")
        expect(text.segments.map(\.id) == [40, 41, 42, 43], "Segment identities are stable and unique across chapters")
        let paragraph = TVStorytellerTextParser(fragments: ["p1"], counterStart: 0)
        expect(paragraph.parse("<html><body><p id='p1'>One <strong id='unrelated'>whole</strong> paragraph.</p><p>Unaligned.</p></body></html>"), "Paragraph-level alignment parses")
        expect(paragraph.segments.first?.text == "One whole paragraph.", "Nested unrelated IDs cannot steal paragraph text")
        expect(paragraph.segments.last?.fragmentId == nil, "An aligned passage cannot consume following unaligned paragraphs")
        let verse = TVStorytellerTextParser(fragments: ["verse"], counterStart: 0)
        expect(verse.parse("<html><body><div id='verse'><p>Line one,<br/>line two.</p><p>Another stanza.</p></div></body></html>"), "Block-level and verse alignment parses")
        expect(verse.segments.count == 1 && verse.segments.first?.text == "Line one, line two. Another stanza.", "A single aligned fragment highlights all its lines and nested blocks")
        let suite = "TVReadAlongRegressionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVReadAlongProgressStore(defaults: defaults)
        let position = TVReadAlongProgressStore.Position(href: "EPUB/Text/two.xhtml", fragmentID: "s1", offset: 3.25, observedAt: Date())
        store.save(position, for: "book-one")
        expect(store.position(for: "book-one") == position, "Resume preserves the chapter-qualified fragment and precise audio offset")
        expect(store.position(for: "book-two") == nil, "Resume positions stay isolated by book")
        expect(TVReadAlongProgressStore(defaults: defaults).position(for: "book-one") == position, "Resume survives recreation of the store")
        print("TV read-along: \(checks) regression checks passed.")
    }
}
