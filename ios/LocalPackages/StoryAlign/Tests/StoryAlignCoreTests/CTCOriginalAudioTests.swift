@preconcurrency import AVFoundation
import XCTest
@testable import StoryAlignCore

final class CTCOriginalAudioTests: XCTestCase, @unchecked Sendable {
    func testCompatibleContainersRequireCompatibleCodecs() {
        XCTAssertEqual(AudioFileProcessor.originalAudioExtension(sourceExtension: "M4B", codecs: [kAudioFormatMPEG4AAC], hasVideo: false), "m4a")
        XCTAssertEqual(AudioFileProcessor.originalAudioExtension(sourceExtension: "mp3", codecs: [kAudioFormatMPEGLayer3], hasVideo: false), "mp3")
        XCTAssertNil(AudioFileProcessor.originalAudioExtension(sourceExtension: "mp4", codecs: [kAudioFormatLinearPCM], hasVideo: false))
        XCTAssertNil(AudioFileProcessor.originalAudioExtension(sourceExtension: "m4a", codecs: [kAudioFormatAppleLossless], hasVideo: false))
        XCTAssertNil(AudioFileProcessor.originalAudioExtension(sourceExtension: "m4a", codecs: [kAudioFormatMPEG4AAC], hasVideo: true))
        XCTAssertNil(AudioFileProcessor.originalAudioExtension(sourceExtension: "wav", codecs: [kAudioFormatLinearPCM], hasVideo: false))
    }

    func testOriginalAudioPreservesBytesAndOneTrackPerInput() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let first = root.appendingPathComponent("first.m4b")
        let second = root.appendingPathComponent("second.mp4")
        let encoded = root.appendingPathComponent("encoded.m4a")
        try makeAudio(at: encoded)
        try manager.copyItem(at: encoded, to: first)
        try manager.copyItem(at: encoded, to: second)
        let originalBytes = try Data(contentsOf: encoded)
        let expectedDuration = try await AVURLAsset(url: encoded).load(.duration).seconds
        let request = try AlignmentRequest(epubURL: root.appendingPathComponent("book.epub"), audioBookURLs: [first, second], sessionDir: root.path)
        let session = AlignmentSession(request: request, config: AlignmentConfig(concurrency: 1))
        let epub = try EpubDocument(opfPath: "OEBPS/content.opf", opfXmlData: Data(), metaInfo: EpubMetaInfo(), unzippedURL: root.appendingPathComponent("epub", isDirectory: true), guide: [], manifest: [], spine: EpubSpine(toc: "", items: []), resources: [])
        let result = try await AudioFileProcessor(session: session).processOriginalAudio(audioURLs: [first, second], epub: epub)
        XCTAssertEqual(result.audioFiles.count, 2)
        for (index, file) in result.audioFiles.enumerated() {
            XCTAssertEqual(file.index, index)
            XCTAssertEqual(file.startTmeInterval, 0)
            XCTAssertEqual(file.duration, expectedDuration, accuracy: 0.001)
            XCTAssertEqual(file.filePath.pathExtension, "m4a")
            XCTAssertEqual(file.mediaType, "audio/mp4")
            XCTAssertTrue(file.filePath.path.hasPrefix(epub.opfURL.deletingLastPathComponent().path + "/"))
            XCTAssertEqual(try Data(contentsOf: file.filePath), originalBytes)
        }
        XCTAssertEqual(try Data(contentsOf: first), originalBytes)
        XCTAssertEqual(try Data(contentsOf: second), originalBytes)
    }

    func testBoundedByteCopyPreservesChunkBoundariesAndRefusesOverwrite() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let destination = root.appendingPathComponent("copy.bin")
        var bytes = Data(repeating: 0xa7, count: 9 * 1_024 * 1_024 + 17)
        bytes[4 * 1_024 * 1_024] = 0xbb
        bytes[bytes.count - 1] = 0x5d
        try bytes.write(to: source)
        try AudioFileProcessor.copyAudioBytes(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertThrowsError(try AudioFileProcessor.copyAudioBytes(from: source, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testCancellationRemovesPartiallyCopiedAudio() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let destination = root.appendingPathComponent("partial.bin")
        let task = Task.detached {
            try AudioFileProcessor.copyAudioBytes(from: URL(fileURLWithPath: "/dev/zero"), to: destination)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !manager.fileExists(atPath: destination.path), ProcessInfo.processInfo.systemUptime < deadline {
            await Task.yield()
        }
        let created = manager.fileExists(atPath: destination.path)
        task.cancel()
        do {
            try await task.value
            XCTFail("An active copy must stop when cancelled")
        } catch is CancellationError {
            XCTAssertTrue(created)
            XCTAssertFalse(manager.fileExists(atPath: destination.path))
        }
    }

    private func makeAudio(at url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<16_000 { channel[index] = sin(Float(index) * 0.1) * 0.1 }
        try file.write(from: buffer)
    }
}
