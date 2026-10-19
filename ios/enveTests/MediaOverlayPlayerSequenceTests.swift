import AVFoundation
import Foundation
import Testing

@testable import enve

@Suite(.serialized) @MainActor
struct MediaOverlayPlayerSequenceTests {
    private static let fileDurations = ["ten.wav": 2.0, "eleven.wav": 0.6, "twelve.wav": 1.0]

    private static func makeClips(skippableChapterTwelveOpening: Bool) -> [AudioOverlayClip] {
        [
            AudioOverlayClip(fragmentId: "ten-a", textHref: "ch10.xhtml", audioSrc: "ten.wav", clipBegin: 0, clipEnd: 0.5),
            AudioOverlayClip(fragmentId: "ten-b", textHref: "ch10.xhtml", audioSrc: "ten.wav", clipBegin: 0.5, clipEnd: 1),
            AudioOverlayClip(fragmentId: "eleven", textHref: "ch11.xhtml", audioSrc: "eleven.wav", clipBegin: 0, clipEnd: 0.5),
            AudioOverlayClip(fragmentId: "twelve-a", textHref: "ch12.xhtml", audioSrc: "twelve.wav", clipBegin: 0, clipEnd: 0.3,
                             skippableRole: skippableChapterTwelveOpening ? "pagebreak" : nil),
            AudioOverlayClip(fragmentId: "twelve-b", textHref: "ch12.xhtml", audioSrc: "twelve.wav", clipBegin: 0.3, clipEnd: 1),
        ]
    }

    private static func writeSilence(to directory: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        for (name, duration) in fileDurations {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(duration * 8_000)))
            buffer.frameLength = buffer.frameCapacity
            try #require(buffer.floatChannelData?[0]).update(repeating: 0, count: Int(buffer.frameLength))
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: format.settings)
            try file.write(from: buffer)
        }
    }

    private static func playToEnd(
        skipSkippables: Bool,
        skippableChapterTwelveOpening: Bool
    ) async throws -> [(clip: Int, at: TimeInterval)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSilence(to: directory)
        let clips = makeClips(skippableChapterTwelveOpening: skippableChapterTwelveOpening)
        // play() restores the persisted speed, which would override the 1x timing asserted here.
        let suiteName = "MediaOverlayPlayerSequenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = MediaOverlayPlayer(defaults: defaults)
        player.skipSkippables = skipSkippables
        player.playbackRate = 1
        player.load(clips: clips, timeline: MediaOverlayTimeline(clips: clips), audioDir: directory)
        defer { player.cleanup() }

        player.play()
        let start = ProcessInfo.processInfo.systemUptime
        var visits: [(clip: Int, at: TimeInterval)] = []
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            player.refreshPositionFromPlayhead()
            if visits.last?.clip != player.currentClipIndex {
                visits.append((player.currentClipIndex, ProcessInfo.processInfo.systemUptime - start))
            }
            if visits.last?.clip == clips.count - 1, !player.isPlaying { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!player.isPlaying)
        return visits
    }

    @Test func fileOverflowPastItsTimelineSpanDoesNotPublishLaterChapters() async throws {
        let visits = try await Self.playToEnd(skipSkippables: false, skippableChapterTwelveOpening: false)
        #expect(visits.map(\.clip) == [0, 1, 2, 3, 4])
    }

    @Test func fileOverflowOntoASkippableClipDoesNotJumpTheAudioPastTheNextChapter() async throws {
        let visits = try await Self.playToEnd(skipSkippables: true, skippableChapterTwelveOpening: true)
        #expect(visits.map(\.clip) == [0, 1, 2, 4])
        let reachedTwelve = try #require(visits.first(where: { $0.clip == 4 })?.at)
        #expect(reachedTwelve >= 2.3)
    }
}
