import AVFoundation
import CryptoKit
import Darwin
import FluidAudio
import UIKit
import XCTest

@testable import enve

nonisolated final class KokoroOnDeviceBenchmarkTests: XCTestCase {
    func testFourVoiceSynthesisAndCache() async throws {
        guard ProcessInfo.processInfo.environment["ENVE_KOKORO_VOICES"] == "1" else {
            throw XCTSkip("Enable ENVE_KOKORO_VOICES for the physical-device voice check.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Verify Kokoro voices on a physical iPhone.")
        #else
        executionTimeAllowance = 600
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KokoroVoiceCheck", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runtime = KokoroTTSRuntime()
        try await runtime.prepare()
        XCTAssertTrue(KokoroTTSRuntime.hasDownloadedVoices)
        let session = AVAudioSession.sharedInstance()
        let previous = (session.category, session.mode, session.categoryOptions)
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        defer {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
        }
        let text = "The library is quiet this evening. Choose the narrator you find most comfortable, and settle in for another chapter."
        var digests = Set<String>()
        var runs: [[String: Any]] = []
        for voice in KokoroTTSVoice.allCases {
            let samples = try await runtime.synthesize(text: text, voice: voice, speed: 1)
            try Self.validate(samples)
            let digest = samples.withUnsafeBufferPointer {
                SHA256.hash(data: Data(buffer: $0)).map { String(format: "%02x", $0) }.joined()
            }
            XCTAssertTrue(digests.insert(digest).inserted, "Voice cache reused another narrator's audio.")
            let cached = try await runtime.synthesize(text: text, voice: voice, speed: 1)
            XCTAssertEqual(cached, samples)
            let url = directory.appendingPathComponent("\(voice.rawValue).wav")
            try Self.writeWAV(samples, to: url)
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            let playing = player.play()
            XCTAssertTrue(playing)
            try await Task.sleep(for: .seconds(player.duration + 0.1))
            player.stop()
            runs.append([
                "voice": voice.rawValue,
                "audioSeconds": player.duration,
                "sha256": digest,
                "playbackStarted": playing,
                "cacheMatches": cached == samples,
            ])
        }
        await runtime.unload()
        let report: [String: Any] = [
            "voices": runs,
            "modelBytes": try Self.modelBytes(),
            "additionalVoiceProfileBytes": 3 * 522_240,
            "sampleRate": KokoroAneConstants.sampleRate,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        #endif
    }

    func testUncachedOnDeviceSynthesis() async throws {
        guard ProcessInfo.processInfo.environment["ENVE_KOKORO_BENCHMARK"] == "1" else {
            throw XCTSkip("Enable ENVE_KOKORO_BENCHMARK for the physical-device benchmark.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Run performance measurements on a physical iPhone.")
        #else
        executionTimeAllowance = 1_200
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KokoroBenchmark", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportURL = directory.appendingPathComponent("report.json")
        var report: [String: Any] = [
            "backend": "FluidAudio KokoroAneManager legacy English",
            "osVersion": await MainActor.run { UIDevice.current.systemVersion },
            "voice": "af_heart",
            "speed": 1.0,
            "sampleRate": KokoroAneConstants.sampleRate,
            "footprintBeforeLoadBytes": Self.footprint(),
            "thermalStateBefore": ProcessInfo.processInfo.thermalState.rawValue,
            "stage": "downloading",
        ]
        func save() throws {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
        }
        try save()
        let manager = KokoroAneManager(variant: .english)
        do {
            let preparationStarted = ContinuousClock.now
            try await KokoroAneResourceDownloader.ensureModels(variant: .english)
            try await KokoroAneResourceDownloader.ensureG2PAssets()
            _ = await KokoroAneResourceDownloader.ensureEnglishLexicon()
            report["stage"] = "loading"
            try save()
            try await manager.initialize()
            report["preparationSeconds"] = Self.seconds(since: preparationStarted)
            report["modelBytesAfterLoad"] = try Self.modelBytes()
            report["footprintAfterLoadBytes"] = Self.footprint()
            report["stage"] = "synthesizing"
            try save()

            let shortText = "Please close the window before you leave. The books beside the desk must stay dry."
            var runs: [[String: Any]] = []
            var sampleURL: URL?
            for label in ["first", "warm1", "warm2", "warm3"] {
                let started = ContinuousClock.now
                let result = try await manager.synthesizeDetailed(text: shortText, voice: "af_heart", speed: 1)
                let elapsed = Self.seconds(since: started)
                try Self.validate(result.samples)
                let audioSeconds = Double(result.samples.count) / Double(KokoroAneConstants.sampleRate)
                let url = directory.appendingPathComponent("\(label).wav")
                try Self.writeWAV(result.samples, to: url)
                sampleURL = url
                runs.append([
                    "label": label,
                    "inputCharacters": shortText.count,
                    "generationSeconds": elapsed,
                    "audioSeconds": audioSeconds,
                    "realTimeFactor": elapsed / audioSeconds,
                    "footprintAfterRunBytes": Self.footprint(),
                ])
                report["runs"] = runs
                try save()
            }

            let passages = [
                "The rain had stopped by the time Mara reached the old library.",
                "She left her coat beside the door and walked between the quiet shelves.",
                "At the far end of the room, a small lamp lit an open book.",
                "Someone had marked a page with a folded map of the valley.",
                "Mara studied the river, the bridge, and the narrow road beyond the hills.",
                "For the first time that morning, she knew where she needed to go.",
                "She closed the book carefully and carried the map back into the daylight.",
            ]
            var longSamples: [Float] = []
            let repeats = max(1, Int(ProcessInfo.processInfo.environment["ENVE_KOKORO_PASSAGE_REPEATS"] ?? "1") ?? 1)
            var passageRuns: [[String: Any]] = []
            let longStarted = ContinuousClock.now
            for index in 0..<repeats {
                let started = ContinuousClock.now
                for text in passages {
                    let result = try await manager.synthesizeDetailed(text: text, voice: "af_heart", speed: 1)
                    try Self.validate(result.samples)
                    longSamples.append(contentsOf: result.samples)
                }
                passageRuns.append([
                    "passage": index + 1,
                    "generationSeconds": Self.seconds(since: started),
                    "footprintAfterPassageBytes": Self.footprint(),
                    "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                ])
                report["passageRuns"] = passageRuns
                try save()
            }
            let elapsed = Self.seconds(since: longStarted)
            let audioSeconds = Double(longSamples.count) / Double(KokoroAneConstants.sampleRate)
            try Self.writeWAV(longSamples, to: directory.appendingPathComponent("long.wav"))
            runs.append([
                "label": "segmentedPassage",
                "segments": passages.count * repeats,
                "inputCharacters": Array(repeating: passages.joined(separator: " "), count: repeats)
                    .joined(separator: " ").count,
                "generationSeconds": elapsed,
                "audioSeconds": audioSeconds,
                "realTimeFactor": elapsed / audioSeconds,
                "footprintAfterRunBytes": Self.footprint(),
            ])
            report["runs"] = runs
            report["stage"] = "playing"
            try save()

            let session = AVAudioSession.sharedInstance()
            let previous = (session.category, session.mode, session.categoryOptions)
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            defer {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
            }
            let player = try AVAudioPlayer(contentsOf: XCTUnwrap(sampleURL))
            player.prepareToPlay()
            let playing = player.play()
            report["playbackStarted"] = playing
            try save()
            XCTAssertTrue(playing)
            try await Task.sleep(for: .seconds(player.duration + 0.1))
            player.stop()
            report["stage"] = "completed"
            report["modelBytesAfterRun"] = try Self.modelBytes()
            report["thermalStateAfter"] = ProcessInfo.processInfo.thermalState.rawValue
            try save()
            await manager.cleanup()
        } catch {
            report["failedStage"] = report["stage"]
            report["stage"] = "failed"
            report["error"] = error.localizedDescription
            try? save()
            await manager.cleanup()
            throw error
        }
        #endif
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    private static func validate(_ samples: [Float]) throws {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite),
            samples.contains(where: { abs($0) > 0.00001 })
        else { throw NSError(domain: "KokoroBenchmark.InvalidAudio", code: 1) }
    }

    private static func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: Double(KokoroAneConstants.sampleRate), channels: 1
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = buffer.frameCapacity
        let destination = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: source.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: KokoroAneConstants.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        try file.write(from: buffer)
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func modelBytes() throws -> Int64 {
        let root = try TtsCacheDirectory.ensure().appendingPathComponent("Models", isDirectory: true)
        var total: Int64 = 0
        for repo in [Repo.kokoroAne, .kokoro] {
            let path = root.appendingPathComponent(repo.folderName, isDirectory: true)
            guard let files = FileManager.default.enumerator(
                at: path, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            ) else { continue }
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
            }
        }
        return total
    }
}
