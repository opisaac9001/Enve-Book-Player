import XCTest
@testable import StoryAlignCore

final class CTCForcedAlignerTests: XCTestCase {
    private func lattice(_ peaks: [Int], classes: Int = 3) -> CTCEmissions {
        var values = [Float](repeating: -12, count: peaks.count * classes)
        for (frame, peak) in peaks.enumerated() { values[frame * classes + peak] = -0.01 }
        return CTCEmissions(values: values, frames: peaks.count, classes: classes, secondsPerFrame: 0.02)
    }

    func testRepeatedCharactersRequireBlank() throws {
        let result = try XCTUnwrap(CTCForcedAligner.align(lattice([0, 1, 1, 0, 1, 0]), labels: [1, 1], blank: 0))
        XCTAssertEqual(result.map(\.startFrame), [1, 4])
        XCTAssertLessThan(result[0].endFrame, result[1].startFrame + 1)
    }

    func testSurroundingSpeechDoesNotShiftKnownText() throws {
        let result = try XCTUnwrap(CTCForcedAligner.align(lattice([2, 2, 0, 1, 0, 2, 0, 1, 1]), labels: [1, 2], blank: 0))
        XCTAssertEqual(result.map(\.startFrame), [3, 5])
    }

    func testImpossiblePathIsRejected() throws {
        XCTAssertNil(try CTCForcedAligner.align(lattice([1, 1]), labels: [1, 1], blank: 0))
        XCTAssertNil(try CTCForcedAligner.align(lattice([]), labels: [1], blank: 0))
        XCTAssertNil(try CTCForcedAligner.align(lattice([1, 2]), labels: [9], blank: 0))
    }

    func testTrellisMemoryIsBounded() throws {
        XCTAssertNil(try CTCForcedAligner.align(lattice([Int](repeating: 1, count: 10_000)), labels: [Int](repeating: 1, count: 500), blank: 0))
    }

    func testWrongTextHasPoorAcousticSupport() throws {
        let result = try XCTUnwrap(CTCForcedAligner.align(lattice([0, 0, 0, 0, 0, 0]), labels: [1, 2], blank: 0))
        XCTAssertTrue(result.allSatisfy { $0.meanLogProbability < -10 })
    }

    func testGreedyDecodeRetainsRepeatedLettersSeparatedByBlank() {
        let result = CTCTextIndex.decode(lattice([1, 1, 0, 1, 2, 2]), blank: 0, space: nil)
        XCTAssertEqual(result.labels, [1, 1, 2])
        XCTAssertEqual(result.frames, [0, 3, 4])
    }

    func testSignalPreEmphasisAndReflection() {
        let samples = (0..<600).map { Float($0) / 600 }
        let signal = QuartzNetModel.prepareSignal(samples)
        XCTAssertEqual(signal.count, 1112)
        XCTAssertEqual(signal[256], samples[0])
        XCTAssertEqual(signal[257], samples[1] - 0.97 * samples[0])
        XCTAssertEqual(signal[255], signal[257])
        XCTAssertEqual(signal[856], signal[854])
    }

    func testWholeBookQualityRejectsSparseMatches() {
        XCTAssertFalse(CTCAlignmentQuality(eligibleSentenceCount: 10_000, acceptedSentenceCount: 3, audioCoverage: 0.001).isUsable)
        XCTAssertFalse(CTCAlignmentQuality(eligibleSentenceCount: 100, acceptedSentenceCount: 69, audioCoverage: 0.8).isUsable)
        XCTAssertTrue(CTCAlignmentQuality(eligibleSentenceCount: 100, acceptedSentenceCount: 70, audioCoverage: 0.8).isUsable)
        XCTAssertFalse(CTCAlignmentQuality(eligibleSentenceCount: 0, acceptedSentenceCount: 0, audioCoverage: 0).isUsable)
    }
}
