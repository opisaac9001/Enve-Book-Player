import AVFoundation
import Foundation
import Testing
@testable import enve

@MainActor
struct PassageStreamingTests {
    @Test func playbackMediaPreservesStreamAuthorizationAndSession() throws {
        let epub = URL(fileURLWithPath: "/fixture/original.epub")
        let tracks = [AudioTrackInfo(index: 0, startOffset: 0, duration: 600,
            contentUrl: "https://example.invalid/audio.m4b", mimeType: "audio/mp4")]
        let media = try #require(PassageAlignmentService.PassageMedia(epub: epub,
            playback: (tracks, ["Authorization": "Bearer fixture"], "playback-one")))
        #expect(media.audio.first?.scheme == "https")
        #expect(media.headers["Authorization"] == "Bearer fixture")
        #expect(media.streamSession == "playback-one")
        #expect(PassageAlignmentService.PassageMedia(epub: epub, playback: (tracks, [:], nil)) == nil)
    }

    @Test func bufferRespondsToThroughputAndStaysBounded() {
        var buffer = PassageBufferPolicy()
        #expect(buffer.listeningSecondsAhead == 120)
        buffer.record(audioSeconds: .nan, wallSeconds: 1)
        buffer.record(audioSeconds: 30, wallSeconds: 0)
        #expect(buffer.rate == nil)
        buffer.record(audioSeconds: 30, wallSeconds: 90)
        #expect(abs(buffer.listeningSecondsAhead - 342) < 0.01)
        for _ in 0..<10 { buffer.record(audioSeconds: 30, wallSeconds: 3_000) }
        #expect(buffer.listeningSecondsAhead == 600)
    }

    @Test func streamedMappingsStayWithinTheirSourceAndPlaybackSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let epub = root.appendingPathComponent("original.epub")
        try Data("Original edition".utf8).write(to: epub)
        let cache = root.appendingPathComponent("identity.json")
        let resolver = PassageMediaIdentityResolver(cacheURL: cache)
        let firstURL = try #require(URL(string: "https://example.invalid/audio/one.m4b?token=fixture"))
        let secondURL = try #require(URL(string: "https://example.invalid/audio/two.m4b?token=fixture"))
        func identity(_ url: URL, session: String) async throws -> PassageMediaIdentity {
            try await resolver.identity(ebookStableId: "ebook", audiobookStableId: "audio", epubURL: epub, audioURLs: [url], streamSession: session)
        }
        let first = try await identity(firstURL, session: "one")
        #expect(try await identity(firstURL, session: "one") == first)
        #expect(try await identity(firstURL, session: "two") != first)
        #expect(try await identity(secondURL, session: "one") != first)
        let restored = PassageMediaIdentityResolver(cacheURL: cache)
        let restoredIdentity = try await restored.identity(ebookStableId: "ebook", audiobookStableId: "audio", epubURL: epub, audioURLs: [firstURL], streamSession: "one")
        #expect(restoredIdentity != first)
        #expect(!(try String(contentsOf: cache, encoding: .utf8)).contains("token=fixture"))
    }

    @Test func streamedWindowKeepsItsRequestedTimeRangeAndHeaders() async throws {
        let server = try DownloadFixtureServer(audio: Self.wave())
        let port = try await server.start()
        defer { server.stop() }
        let track = PassageTrack(index: 0, url: try #require(URL(string: "http://127.0.0.1:\(port)/audio.wav")),
            digest: "fixture", duration: 10, bookOffset: 0, headers: ["Authorization": "Bearer fixture"])
        let file = try await PassageAudioWindow.extract(track: track, start: 3, end: 4.2)
        defer { try? FileManager.default.removeItem(at: file) }
        let audio = try AVAudioFile(forReading: file)
        #expect(abs(Double(audio.length) / audio.processingFormat.sampleRate - 1.2) < 0.15)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let energy = (0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) }
        #expect(sqrt(energy / Double(buffer.frameLength)) > 0.2)
        #expect(!server.rangeRequests.isEmpty)
    }

    @Test func streamedM4BSeeksUsingAnIndexBeyondTheAudioData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wave = root.appendingPathComponent("input.wav")
        let encoded = root.appendingPathComponent("input.m4a")
        try Self.wave().write(to: wave)
        let input = try AVAudioFile(forReading: wave)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)))
        try input.read(into: buffer)
        do {
            let output = try AVAudioFile(forWriting: encoded, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
            ])
            try output.write(from: buffer)
        }
        var data = try Data(contentsOf: encoded)
        var offset = 0
        while offset + 8 <= data.count {
            let size = data[offset..<offset + 4].reduce(0) { $0 * 256 + Int($1) }
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            if type == "moov" { break }
            try #require(size >= 8)
            offset += size
        }
        try #require(offset + 8 <= data.count)
        let moovSize = data[offset..<offset + 4].reduce(0) { $0 * 256 + Int($1) }
        let moov = data.subdata(in: offset..<offset + moovSize)
        var replacement = Data(data[offset..<offset + 4])
        replacement.append(contentsOf: "free".utf8)
        replacement.append(Data(count: moovSize - 8))
        data.replaceSubrange(offset..<offset + moovSize, with: replacement)
        var padding = Data([0, 64, 0, 0])
        padding.append(contentsOf: "free".utf8)
        padding.append(Data(count: 4_194_304 - 8))
        data.append(padding)
        data.append(moov)
        let padded = root.appendingPathComponent("padded.m4a")
        try data.write(to: padded)
        #expect(try AVAudioFile(forReading: padded).length > 0)
        let server = try DownloadFixtureServer(audio: data)
        let port = try await server.start()
        defer { server.stop() }
        let track = PassageTrack(index: 0, url: try #require(URL(string: "http://127.0.0.1:\(port)/audio.wav")),
            digest: "fixture", duration: 10, bookOffset: 0, headers: ["Authorization": "Bearer fixture"])
        let result = try await PassageAudioWindow.extract(track: track, start: 3, end: 4.2)
        defer { try? FileManager.default.removeItem(at: result) }
        let audio = try AVAudioFile(forReading: result)
        #expect(abs(Double(audio.length) / audio.processingFormat.sampleRate - 1.2) < 0.15)
        #expect(server.audioBytesServed < data.count / 2)
    }

    @Test func cancellingAStalledStreamStopsPreparationPromptly() async throws {
        let server = try DownloadFixtureServer(audio: Self.wave())
        let port = try await server.start()
        defer { server.stop() }
        let track = PassageTrack(index: 0, url: try #require(URL(string: "http://127.0.0.1:\(port)/hold-audio.wav")),
            digest: "fixture", duration: 10, bookOffset: 0, headers: ["Authorization": "Bearer fixture"],
            networkSession: URLSession(configuration: .ephemeral))
        let profileSession = try #require(track.networkSession)
        defer { profileSession.invalidateAndCancel() }
        let task = Task { try await PassageAudioWindow.extract(track: track, start: 3, end: 4.2) }
        for _ in 0..<100 where server.heldCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(2))
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/audio.wav")))
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        let (data, response) = try await profileSession.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(!data.isEmpty)
    }

    private static func wave() -> Data {
        let rate = 16_000
        let count = rate * 10
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + count * 2)); text("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(rate)); number(UInt32(rate * 2))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(count * 2))
        for sample in 0..<count {
            let value = sample < rate * 2 ? 0 : Int16(sin(Double(sample) * 2 * .pi * 440 / Double(rate)) * 16_000)
            number(Int16(value))
        }
        return data
    }
}
