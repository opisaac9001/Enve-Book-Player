import XCTest
@testable import StoryAlignCore

final class CTCTextIndexTests: XCTestCase {
    private let vocabulary = Dictionary(uniqueKeysWithValues: Array("abcdefghijklmnopqrstuvwxyz").enumerated().map { ($0.element, $0.offset + 1) })
    private let passage = "The old sailor opened the wooden door and looked across the quiet harbor. A bright orange lantern stood beside the folded map."

    private func chapter(_ sentences: [String], index: Int = 0) -> EpubManifestItem {
        EpubManifestItem(id: "chapter\(index)", href: "chapter\(index).xhtml", mediaType: "application/xhtml+xml", properties: nil, spineItemIndex: index, text: sentences.joined(separator: " "), xmlData: nil, hasScript: false, xhtmlSentences: sentences, name: "Chapter \(index)", filePath: nil)
    }

    private func decoded(_ text: String) -> CTCDecodedText {
        let labels = text.lowercased().compactMap { vocabulary[$0] }
        return CTCDecodedText(labels: labels, frames: labels.indices.map { $0 * 3 })
    }

    func testDistinctPassageFindsOrderedAnchors() throws {
        let index = CTCTextIndex(chapters: [chapter([passage])], vocabulary: vocabulary)
        let anchors = try index.anchors(for: decoded(passage))
        XCTAssertGreaterThan(anchors.count, 4)
        XCTAssertTrue(zip(anchors, anchors.dropFirst()).allSatisfy { $0.character < $1.character && $0.frame < $1.frame })
    }

    func testUnrelatedAudioDoesNotLocateBook() throws {
        let index = CTCTextIndex(chapters: [chapter([passage])], vocabulary: vocabulary)
        XCTAssertTrue(try index.anchors(for: decoded("Welcome to an entirely unrelated story about mountains and a journey through the desert.")).isEmpty)
    }

    func testRepeatedPassageNeedsDisambiguation() throws {
        let index = CTCTextIndex(chapters: [chapter([passage]), chapter([passage], index: 1)], vocabulary: vocabulary)
        XCTAssertTrue(try index.anchors(for: decoded(passage)).isEmpty)
    }

    func testOriginalSentenceLocationsSurviveNormalization() {
        let index = CTCTextIndex(chapters: [chapter(["The sailor’s lantern.", "The folded map."])], vocabulary: vocabulary)
        XCTAssertEqual(index.sentences.count, 2)
        XCTAssertEqual(index.sentences[0].text, "The sailor’s lantern.")
        XCTAssertEqual(index.sentences[1].sentence, 1)
        XCTAssertEqual(index.sentences[0].range.upperBound, index.sentences[1].range.lowerBound)
    }

    func testWindowMatcherProducesSentenceTimingFromProbabilities() throws {
        let index = CTCTextIndex(chapters: [chapter(["A sailor walks home."])], vocabulary: vocabulary)
        var values: [Float] = []
        for label in index.labels {
            for peak in [28, label, label] {
                var row = [Float](repeating: -12, count: 29)
                row[peak] = -0.01
                values.append(contentsOf: row)
            }
        }
        let emissions = CTCEmissions(values: values, frames: index.labels.count * 3, classes: 29, secondsPerFrame: 0.02)
        let anchors = [CTCTextAnchor(character: 0, frame: 1), CTCTextAnchor(character: index.labels.count - 1, frame: (index.labels.count - 1) * 3 + 1)]
        let audio = AudioFile(startTmeInterval: 0, endTmeInterval: 10, filePath: URL(fileURLWithPath: "/fixture.mp3"), index: 0)
        let matches = try CTCWindowMatcher.match(emissions: emissions, anchors: anchors, index: index, audio: audio, start: 2, blank: 28)
        let ordered = try CTCWindowMatcher.ordered(matches)
        let match = try XCTUnwrap(ordered.first)
        XCTAssertEqual(ordered.count, 1)
        XCTAssertEqual(match.candidate.sentence.xhtmlSentence, "A sailor walks home.")
        XCTAssertEqual(match.candidate.sentence.sentenceRange.start, 1.74, accuracy: 0.001)
        XCTAssertGreaterThan(match.candidate.sentence.sentenceRange.end, match.candidate.sentence.sentenceRange.start)
        XCTAssertGreaterThan(match.candidate.score, -0.02)
    }
}
