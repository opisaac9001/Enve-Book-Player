#if os(iOS) && !targetEnvironment(macCatalyst)
import AVFoundation
import CryptoKit
import Foundation
import Testing
import XCTest

@testable import enve

nonisolated struct KokoroONNXTests {
    @Test func frontendDiphthongsUseKokoroTokens() throws {
        let vocabulary: [String: Int64] = ["A": 24, "O": 31, "I": 25, "Y": 41, "W": 39, " ": 16]
        let chunks = try KokoroONNXModel.tokenChunks(ipa: "eɪ oʊ aɪ ɔɪ aʊ", vocabulary: vocabulary)
        #expect(chunks == [[0, 24, 16, 31, 16, 25, 16, 41, 16, 39, 0]])
    }

    @Test func longPhonemeSequencesKeepEveryTokenWithinTheModelLimit() throws {
        let vocabulary: [String: Int64] = ["a": 43, " ": 16]
        for text in [String(repeating: "a", count: 1_533), String(repeating: "aaaa ", count: 400), " " + String(repeating: "a", count: 1_533)] {
            let chunks = try KokoroONNXModel.tokenChunks(ipa: text, vocabulary: vocabulary)
            #expect(chunks.allSatisfy { $0.count <= 512 && $0.count > 2 && $0.first == 0 && $0.last == 0 })
            let letterCount = chunks.flatMap { $0.dropFirst().dropLast() }.filter { $0 == 43 }.count
            let expectedCount = text.filter { $0 == "a" }.count
            #expect(letterCount == expectedCount)
        }
    }

    @Test func unsupportedSymbolsCannotProduceAnEmptyInference() {
        #expect(throws: (any Error).self) {
            try KokoroONNXModel.tokenChunks(ipa: "🙂", vocabulary: ["a": 43])
        }
    }

    @Test func voiceRowsExcludeTheBoundaryTokens() {
        let voice = (0..<510).flatMap { [Float](repeating: Float($0), count: 256) }
        #expect(KokoroONNXModel.style(voice: voice, phonemeCount: 1) == [Float](repeating: 0, count: 256))
        #expect(KokoroONNXModel.style(voice: voice, phonemeCount: 510) == [Float](repeating: 509, count: 256))
    }

    @Test func matchingSizeAloneDoesNotValidateAModelDownload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("model.onnx")
        let bytes = Data([1, 2, 3, 4])
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let expected = KokoroONNXAssets.File(path: "model.onnx", size: bytes.count, sha256: digest)
        try bytes.write(to: file)
        #expect(KokoroONNXAssets.valid(expected, at: file))
        try Data([4, 3, 2, 1]).write(to: file)
        #expect(!KokoroONNXAssets.valid(expected, at: file))
        try Data([1, 2]).write(to: file)
        #expect(!KokoroONNXAssets.valid(expected, at: file))
    }
}

nonisolated final class KokoroONNXIntegrationTests: XCTestCase {
    func testCPUVoicesPlaybackCacheAndRepeatedSynthesis() async throws {
        guard ProcessInfo.processInfo.environment["ENVE_KOKORO_ONNX"] == "1" else {
            throw XCTSkip("Enable ENVE_KOKORO_ONNX to download and exercise the real CPU model.")
        }
        executionTimeAllowance = 1_200
        let started = ContinuousClock.now
        let model = try await KokoroONNXModel.prepare(progress: nil)
        XCTAssertTrue(KokoroONNXAssets.areDownloaded)
        let text = "The library is quiet this evening. Choose your narrator and settle in for another chapter."
        var hashes = Set<String>()
        var audioSeconds: [String: Double] = [:]
        var playbackSample: [Float] = []
        for voice in KokoroTTSVoice.allCases {
            let samples = try await model.synthesize(text: text, voice: voice, speed: 1)
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 4 })
            XCTAssertGreaterThan(samples.count, 24_000)
            let digest = samples.withUnsafeBufferPointer { SHA256.hash(data: Data(buffer: $0)).description }
            XCTAssertTrue(hashes.insert(digest).inserted)
            audioSeconds[voice.rawValue] = Double(samples.count) / 24_000
            playbackSample = samples
        }
        let fast = try await model.synthesize(text: text, voice: .heart, speed: 1.5)
        XCTAssertLessThan(Double(fast.count) / 24_000, audioSeconds[KokoroTTSVoice.heart.rawValue]!)

        let passages = [
            "Mara reached the old library after the rain had stopped.",
            "She left her coat beside the door and walked between the quiet shelves.",
            "At the far end of the room, a small lamp lit an open book.",
            "Someone had marked a page with a folded map of the valley.",
            "The sign read nineteen ninety, and the ticket cost five dollars.",
        ]
        let repeats = max(1, Int(ProcessInfo.processInfo.environment["ENVE_KOKORO_ONNX_REPEATS"] ?? "4") ?? 4)
        for _ in 0..<repeats {
            for passage in passages {
                let samples = try await model.synthesize(text: passage, voice: .heart, speed: 1)
                XCTAssertGreaterThan(samples.count, 0)
            }
        }

        let runtime = KokoroTTSRuntime()
        let first = try await runtime.synthesize(text: text, voice: .michael, speed: 1)
        let cached = try await runtime.synthesize(text: text, voice: .michael, speed: 1)
        XCTAssertEqual(first, cached)
        let cancelled = Task { try await runtime.synthesize(text: text, voice: .michael, speed: 1) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled narration request returned cached audio.")
        } catch is CancellationError {
        }
        await runtime.unload()
        let reopened = try await KokoroONNXModel.prepare(progress: nil)
        let resumed = try await reopened.synthesize(text: "Welcome back to the library.", voice: .bella, speed: 1)
        XCTAssertFalse(resumed.isEmpty)

        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(playbackSample.count))!
        buffer.frameLength = buffer.frameCapacity
        playbackSample.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: playbackSample.count) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-onnx-validation.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let player = try AVAudioPlayer(contentsOf: url)
        XCTAssertTrue(player.prepareToPlay())
        XCTAssertTrue(player.play())
        try await Task.sleep(for: .milliseconds(250))
        player.stop()
        try? FileManager.default.removeItem(at: url)
        print("Kokoro ONNX CPU validation: voices=\(audioSeconds), repeatedCalls=\(repeats * passages.count), elapsed=\(started.duration(to: .now))")
    }
}
#endif
