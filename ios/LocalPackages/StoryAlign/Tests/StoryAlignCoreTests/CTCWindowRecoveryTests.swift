import XCTest
@testable import StoryAlignCore

final class CTCWindowRecoveryTests: XCTestCase {
    private let vocabulary = Dictionary(uniqueKeysWithValues: Array("abcdefghijklmnopqrstuvwxyz").enumerated().map { ($0.element, $0.offset + 1) })

    private func candidate(_ id: Int, start: Double, end: Double, file: Int = 0) -> CTCSentenceCandidate {
        let audio = AudioFile(startTmeInterval: 0, endTmeInterval: 200, filePath: URL(fileURLWithPath: "/fixture\(file).mp3"), index: file)
        let range = SentenceRange(id: id, start: start, end: end, audioFile: audio, timeStamps: [])
        let sentence = AlignedSentence(xhtmlSentence: "Sentence \(id)", sentenceId: id, sentenceRange: range, matchText: nil, matchOffset: nil, matchType: nil)
        return CTCSentenceCandidate(sentence: sentence, score: -0.1)
    }

    func testLaterAudioOutlierDoesNotDiscardCorrectSuffix() throws {
        let matches = [0: candidate(0, start: 0, end: 2), 1: candidate(1, start: 100, end: 102), 2: candidate(2, start: 3, end: 5), 3: candidate(3, start: 6, end: 8), 4: candidate(4, start: 9, end: 11)]
        let chain = try CTCWindowMatcher.ordered(matches)
        XCTAssertEqual(chain.map(\.index), [0, 2, 3, 4])
    }

    func testEqualStartsNeverProduceZeroDuration() throws {
        let chain = try CTCWindowMatcher.ordered([0: candidate(0, start: 1, end: 1.2), 1: candidate(1, start: 1, end: 1.4), 2: candidate(2, start: 1.5, end: 2)])
        XCTAssertEqual(chain.count, 2)
        XCTAssertTrue(chain.allSatisfy { $0.candidate.sentence.sentenceRange.duration >= 0.04 })
    }

    func testShortCalibrationOverlapIsReconciled() throws {
        let chain = try CTCWindowMatcher.ordered([0: candidate(0, start: 1, end: 2.2), 1: candidate(1, start: 2, end: 3)])
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(chain[0].candidate.sentence.sentenceRange.end, 2)
        XCTAssertTrue(chain.allSatisfy { $0.candidate.sentence.sentenceRange.duration > 0 })
    }

    func testFileOrderIsPartOfSentenceChain() throws {
        let chain = try CTCWindowMatcher.ordered([0: candidate(0, start: 100, end: 102, file: 0), 1: candidate(1, start: 0, end: 2, file: 1), 2: candidate(2, start: 103, end: 105, file: 0), 3: candidate(3, start: 3, end: 5, file: 1)])
        XCTAssertEqual(chain.map(\.index), [0, 1, 3])
    }

    func testAudioPlacementPreservesPresentationTimeGaps() {
        let late = CTCAudioReader.placement(bufferOffset: 1600, sampleCount: 3200, existing: 0, limit: 8000)
        XCTAssertEqual(late.padding, 1600)
        XCTAssertEqual(late.skip, 0)
        XCTAssertEqual(late.take, 3200)
        let early = CTCAudioReader.placement(bufferOffset: -160, sampleCount: 3200, existing: 0, limit: 8000)
        XCTAssertEqual(early.padding, 0)
        XCTAssertEqual(early.skip, 160)
        XCTAssertEqual(early.take, 3040)
        let gap = CTCAudioReader.placement(bufferOffset: 1500, sampleCount: 3200, existing: 1000, limit: 8000)
        XCTAssertEqual(gap.padding, 500)
        XCTAssertEqual(gap.take, 3200)
        let outside = CTCAudioReader.placement(bufferOffset: 10_000, sampleCount: 3200, existing: 0, limit: 8000)
        XCTAssertEqual(outside.padding, 8000)
        XCTAssertEqual(outside.take, 0)
    }

    func testLongestChainMatchesExhaustiveDynamicProgramming() throws {
        var seed: UInt64 = 71
        func random(_ limit: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % UInt64(limit))
        }
        for _ in 0..<20 {
            var candidates: [Int: CTCSentenceCandidate] = [:]
            for index in 0..<80 {
                let start = Double(random(200)) / 10
                candidates[index] = candidate(index, start: start, end: start + Double(random(30) + 1) / 10, file: random(3))
            }
            var lengths = [Int](repeating: 1, count: candidates.count)
            for current in 0..<candidates.count {
                let rhs = candidates[current]!.sentence.sentenceRange
                for previous in 0..<current {
                    let lhs = candidates[previous]!.sentence.sentenceRange
                    if lhs.audioFile.index < rhs.audioFile.index || (lhs.audioFile.index == rhs.audioFile.index && lhs.start <= rhs.start - 0.04 && lhs.end <= min(rhs.start + 0.499, rhs.end - 0.04)) {
                        lengths[current] = max(lengths[current], lengths[previous] + 1)
                    }
                }
            }
            let chain = try CTCWindowMatcher.ordered(candidates)
            XCTAssertEqual(chain.count, lengths.max())
            XCTAssertTrue(chain.allSatisfy { $0.candidate.sentence.sentenceRange.duration >= 0.04 })
        }
    }

    func testTwentySecondSentenceCrossingThirtyEightSecondChunkSeam() throws {
        let text = "The old sailor opened the wooden door and looked across the quiet harbor while the captain prepared the folded map."
        let chapter = EpubManifestItem(id: "chapter", href: "chapter.xhtml", mediaType: "application/xhtml+xml", properties: nil, spineItemIndex: 0, text: text, xmlData: nil, hasScript: false, xhtmlSentences: [text], name: "Harbor", filePath: nil)
        let index = CTCTextIndex(chapters: [chapter], vocabulary: vocabulary)
        for overlap in [2.0, 8.0] {
            let frameCount = Int((76 - overlap) / 0.02)
            var values = [Float](repeating: -12, count: frameCount * 29)
            for frame in 0..<frameCount { values[frame * 29 + 28] = -0.01 }
            for (character, label) in index.labels.enumerated() {
                let frame = 1250 + Int((Double(character) * 1000 / Double(index.labels.count - 1)).rounded())
                values[frame * 29 + 28] = -12
                values[frame * 29 + label] = -0.01
            }
            let full = CTCEmissions(values: values, frames: frameCount, classes: 29, secondsPerFrame: 0.02)
            let previous = CTCEmissionWindow(start: 0, emissions: full.slice(0..<1900))
            let currentStart = 38 - overlap
            let current = CTCEmissionWindow(start: currentStart, emissions: full.slice(Int(currentStart / 0.02)..<frameCount))
            let joined = try previous.joining(current)
            XCTAssertLessThanOrEqual(Double(joined.emissions.frames) * joined.emissions.secondsPerFrame, 74)
            let audio = AudioFile(startTmeInterval: 0, endTmeInterval: 76 - overlap, filePath: URL(fileURLWithPath: "/fixture.mp3"), index: 0)
            let decoded = CTCTextIndex.decode(joined.emissions, blank: 28, space: 0)
            let anchors = try index.anchors(for: decoded)
            XCTAssertGreaterThan(anchors.count, 3)
            let matches = try CTCWindowMatcher.match(emissions: joined.emissions, anchors: anchors, index: index, audio: audio, start: joined.start, blank: 28)
            let match = try XCTUnwrap(matches[0])
            XCTAssertEqual(match.sentence.sentenceRange.start, 24.72, accuracy: 0.02)
            XCTAssertEqual(match.sentence.sentenceRange.end, 44.9, accuracy: 0.02)
            let partialAnchors = try index.anchors(for: CTCTextIndex.decode(previous.emissions, blank: 28, space: 0))
            XCTAssertTrue(try CTCWindowMatcher.match(emissions: previous.emissions, anchors: partialAnchors, index: index, audio: audio, start: 0, blank: 28).isEmpty)
        }
    }
}
