import AVFoundation
import Foundation
import Testing

@testable import enve

@Suite(.serialized) @MainActor
struct MediaOverlayPlayerPositionTests {
    @Test func pausedSeeksKeepTheirTargetUntilTheAudioPlayerCatchesUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        samples.update(repeating: 0, count: Int(buffer.frameLength))
        for name in ["first.wav", "second.wav"] {
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: format.settings)
            try file.write(from: buffer)
        }
        let clips = [
            AudioOverlayClip(fragmentId: "first", textHref: "one.xhtml", audioSrc: "first.wav", clipBegin: 0, clipEnd: 15),
            AudioOverlayClip(fragmentId: "middle", textHref: "one.xhtml", audioSrc: "first.wav", clipBegin: 15, clipEnd: 30),
            AudioOverlayClip(fragmentId: "last", textHref: "two.xhtml", audioSrc: "second.wav", clipBegin: 10, clipEnd: 30),
        ]
        let player = MediaOverlayPlayer()
        player.load(
            clips: clips,
            timeline: MediaOverlayTimeline(clips: clips, audioDurationsBySource: ["first.wav": 30, "second.wav": 30]),
            audioDir: directory
        )
        defer { player.cleanup() }

        player.remoteSeek(to: 22)
        player.refreshPositionFromPlayhead()
        #expect(player.currentClipIndex == 1)
        #expect(abs(player.currentTime - 22) < 0.1)
        player.seekToFragment("last", preferredHref: "two.xhtml")
        player.refreshPositionFromPlayhead()
        #expect(player.currentClipIndex == 2)
        #expect(abs(player.currentTime - 40) < 0.1)

        try await Task.sleep(for: .seconds(1))
        player.refreshPositionFromPlayhead()
        #expect(player.currentClipIndex == 2)
        #expect(abs(player.currentTime - 40) < 0.1)
        #expect(!player.isPlaying)

        player.seekToFragment("middle", preferredHref: "one.xhtml")
        player.refreshPositionFromPlayhead()
        #expect(player.currentClipIndex == 1)
        #expect(abs(player.currentTime - 15) < 0.1)
        try await Task.sleep(for: .seconds(1))
        #expect(abs(player.currentTime - 15) < 0.1)

        for _ in 0..<3 {
            player.remotePlay()
            #expect(player.isPlaying)
            try await Task.sleep(for: .milliseconds(100))
            player.remotePause()
            #expect(!player.isPlaying)
        }
        player.remoteToggle()
        #expect(player.isPlaying)
        player.remoteToggle()
        #expect(!player.isPlaying)
    }
}
