import XCTest
@testable import StoryAlignCore

final class CTCPassageAnalyzerTests: XCTestCase {
    private let vocabulary = Dictionary(uniqueKeysWithValues: Array("abcdefghijklmnopqrstuvwxyz'").enumerated().map { ($0.element, $0.offset + 1) })
    private let sentences = [
        "The old sailor opened the wooden door and looked across the quiet harbor.",
        "A bright orange lantern stood beside the folded map on the table.",
        "Rain drummed against the windows while the kettle began to whistle.",
        "Margaret counted seven silver coins and hid them beneath her pillow.",
        "Far below the cliffs, the fishing boats rocked gently in the evening tide as gulls circled overhead.",
        "Nobody in the village remembered when the lighthouse keeper had arrived.",
        "Thomas wrapped his scarf twice around his neck before stepping outside.",
        "The church bell rang twelve times, and the market square fell silent.",
    ]
    // Sentence four crosses the first window's trailing seam at 38 s and starts before the second window.
    private let timings: [(Double, Double)] = [(1, 8), (9, 15), (16, 22), (23, 28.8), (29.5, 41), (42, 49), (50, 56), (57, 63)]
    private let duration = 66.0

    private func chapter(_ sentences: [String], index: Int = 0) -> EpubManifestItem {
        EpubManifestItem(id: "chapter\(index)", href: "chapter\(index).xhtml", mediaType: "application/xhtml+xml", properties: nil, spineItemIndex: index, text: sentences.joined(separator: " "), xmlData: nil, hasScript: false, xhtmlSentences: sentences, name: "Chapter \(index)", filePath: nil)
    }

    private func emissions(index: CTCTextIndex, spoken: [(sentence: Int, start: Double, end: Double)], labelsOverride: [[Int]]? = nil) -> CTCEmissions {
        let frames = Int(duration / 0.02)
        var values = [Float](repeating: -12, count: frames * 29)
        for frame in 0..<frames { values[frame * 29 + 28] = -0.01 }
        for (offset, item) in spoken.enumerated() {
            let labels = labelsOverride?[offset] ?? Array(index.labels[index.sentences[item.sentence].range])
            let first = Int(item.start / 0.02)
            let last = Int(item.end / 0.02)
            for (character, label) in labels.enumerated() {
                let frame = first + Int((Double(character) * Double(last - first) / Double(max(labels.count - 1, 1))).rounded())
                values[frame * 29 + 28] = -12
                values[frame * 29 + label] = -0.01
            }
        }
        return CTCEmissions(values: values, frames: frames, classes: 29, secondsPerFrame: 0.02)
    }

    private func window(_ window: CTCPassageWindow, from full: CTCEmissions) -> CTCEmissionWindow {
        CTCEmissionWindow(start: window.start, emissions: full.slice(Int(window.start / 0.02)..<min(full.frames, Int(window.end / 0.02))))
    }

    private var audio: AudioFile {
        AudioFile(startTmeInterval: 0, endTmeInterval: duration, filePath: URL(fileURLWithPath: "/fixture.mp3"), index: 0)
    }

    func testGridOwnershipTilesEveryTrackWithoutOverlap() {
        for length in [0.5, 37.0, 38.0, 66.0, 3_600.3] {
            let grid = CTCPassageWindow.grid(trackDuration: length)
            XCTAssertFalse(grid.isEmpty)
            XCTAssertEqual(grid.first?.ownedEndStart, 0)
            XCTAssertEqual(grid.last?.end, length)
            for (lhs, rhs) in zip(grid, grid.dropFirst()) {
                XCTAssertEqual(lhs.ownedEndLimit, rhs.ownedEndStart)
                XCTAssertEqual(rhs.start - lhs.start, 30)
                XCTAssertLessThan(lhs.ownedEndLimit, lhs.end)
            }
            for end in stride(from: 0.0, through: length, by: 0.37) {
                XCTAssertEqual(grid.filter { $0.owns(end: end) }.count, 1, "end \(end) of \(length)")
            }
        }
    }

    func testSeamSentenceIsFinalizedOnceByTheJoinedWindow() throws {
        let index = CTCTextIndex(chapters: [chapter(sentences)], vocabulary: vocabulary)
        let full = emissions(index: index, spoken: timings.enumerated().map { ($0.offset, $0.element.0, $0.element.1) })
        let grid = CTCPassageWindow.grid(trackDuration: duration)
        XCTAssertEqual(grid.count, 2)

        let first = try CTCPassageAnalyzer.finalizedMatches(window: grid[0], previous: nil, current: window(grid[0], from: full), index: index, audio: audio, blank: 28, space: 0)
        XCTAssertEqual(first.matches.map(\.sentenceIndex), [0, 1, 2, 3])

        let isolated = try CTCPassageAnalyzer.finalizedMatches(window: grid[1], previous: nil, current: window(grid[1], from: full), index: index, audio: audio, blank: 28, space: 0)
        XCTAssertFalse(isolated.matches.map(\.sentenceIndex).contains(4), "A window without its predecessor cannot finalize a sentence that began earlier")

        let joined = try CTCPassageAnalyzer.finalizedMatches(window: grid[1], previous: window(grid[0], from: full), current: window(grid[1], from: full), index: index, audio: audio, blank: 28, space: 0)
        XCTAssertEqual(joined.matches.map(\.sentenceIndex), [4, 5, 6, 7])
        let seam = try XCTUnwrap(joined.matches.first)
        XCTAssertEqual(seam.start, 29.5, accuracy: 0.35)
        XCTAssertEqual(seam.end, 41, accuracy: 0.2)
        XCTAssertTrue(Set(first.matches.map(\.sentenceIndex)).isDisjoint(with: joined.matches.map(\.sentenceIndex)))
    }

    func testRepeatedPassageIsNotAccepted() throws {
        let index = CTCTextIndex(chapters: [chapter(Array(sentences[0..<4])), chapter(Array(sentences[0..<4]), index: 1)], vocabulary: vocabulary)
        let full = emissions(index: index, spoken: (0..<4).map { ($0, timings[$0].0, timings[$0].1) })
        let grid = CTCPassageWindow.grid(trackDuration: duration)
        let result = try CTCPassageAnalyzer.finalizedMatches(window: grid[0], previous: nil, current: window(grid[0], from: full), index: index, audio: audio, blank: 28, space: 0)
        XCTAssertTrue(result.matches.isEmpty)
    }

    func testUnrelatedNarrationIsNotAccepted() throws {
        let index = CTCTextIndex(chapters: [chapter(sentences)], vocabulary: vocabulary)
        let unrelated = [
            "Welcome to a completely different story about deserts and mountain caravans.",
            "Engineers designed the bridge using steel cables and concrete towers.",
            "Volcanic islands formed slowly beneath the warm southern ocean currents.",
            "Every spring the orchards bloom with pale pink apple blossoms everywhere.",
        ].map { $0.lowercased().compactMap { vocabulary[$0] } }
        let full = emissions(index: index, spoken: (0..<4).map { ($0, timings[$0].0, timings[$0].1) }, labelsOverride: unrelated)
        let grid = CTCPassageWindow.grid(trackDuration: duration)
        let result = try CTCPassageAnalyzer.finalizedMatches(window: grid[0], previous: nil, current: window(grid[0], from: full), index: index, audio: audio, blank: 28, space: 0)
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.anchorCount, 0)
    }

    func testSentenceListKeepsOriginalIdentityAndUTF16Offsets() {
        let root = URL(fileURLWithPath: "/book", isDirectory: true)
        let first = EpubManifestItem(id: "c1", href: "c1.xhtml", mediaType: "application/xhtml+xml", properties: nil, spineItemIndex: 0, text: nil, xmlData: Data(count: 2048), hasScript: false, xhtmlSentences: ["Café 🙂.", "Two."], name: "One", filePath: URL(fileURLWithPath: "/book/OEBPS/Text/c1.xhtml"))
        let second = EpubManifestItem(id: "c2", href: "c2.xhtml", mediaType: "application/xhtml+xml", properties: nil, spineItemIndex: 1, text: nil, xmlData: Data(count: 2048), hasScript: false, xhtmlSentences: ["Three."], name: "Two", filePath: URL(fileURLWithPath: "/book/OEBPS/Text/c2.xhtml"))
        let list = CTCPassageAnalyzer.sentences(chapters: [first, second], root: root)
        XCTAssertEqual(list.map(\.href), ["OEBPS/Text/c1.xhtml", "OEBPS/Text/c1.xhtml", "OEBPS/Text/c2.xhtml"])
        XCTAssertEqual(list.map(\.sentence), [0, 1, 0])
        XCTAssertEqual(list[1].chapterProgression, 8.0 / 12.0, accuracy: 0.000_1)
        XCTAssertEqual(list[2].totalProgression, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(list[1].totalProgression, 0.5 * 8.0 / 12.0, accuracy: 0.000_1)
    }
}
