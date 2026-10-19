import AVFoundation
import Foundation
import os
import Testing

@testable import enve

@Suite(.serialized) @MainActor
struct MediaOverlayPlayerPositionTests {
    @Test func naturalPlaybackVisitsEveryChapterAcrossSeparateAudioFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = buffer.frameCapacity
        try #require(buffer.floatChannelData?[0]).update(repeating: 0, count: Int(buffer.frameLength))
        var clips: [AudioOverlayClip] = []
        for index in 0..<4 {
            let name = "chapter-\(index).wav"
            let audio = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: format.settings)
            try audio.write(from: buffer)
            clips.append(AudioOverlayClip(fragmentId: "chapter-\(index)", textHref: "chapter-\(index).xhtml",
                                          audioSrc: name, clipBegin: 0, clipEnd: 2))
        }
        let suiteName = "MediaOverlayPlayerPositionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = MediaOverlayPlayer(defaults: defaults)
        player.skipSkippables = false
        player.playbackRate = 1
        player.load(clips: clips, timeline: MediaOverlayTimeline(clips: clips,
                    audioDurationsBySource: Dictionary(uniqueKeysWithValues: clips.map { ($0.audioSrc, 2.0) })),
                    audioDir: directory)
        defer { player.cleanup() }
        let endedFiles = OSAllocatedUnfairLock(initialState: Set<String>())
        let observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: nil, queue: .main) { notification in
                guard let item = notification.object as? AVPlayerItem else { return }
                MainActor.assumeIsolated {
                    guard let asset = item.asset as? AVURLAsset,
                        asset.url.deletingLastPathComponent().path == directory.path
                    else { return }
                    _ = endedFiles.withLock { $0.insert(asset.url.lastPathComponent) }
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        let startedAt = ProcessInfo.processInfo.systemUptime
        player.play()
        var visited: [Int] = []
        var samples: [(time: TimeInterval, audio: TimeInterval)] = []
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            player.refreshPositionFromPlayhead()
            let sample = (time: ProcessInfo.processInfo.systemUptime, audio: player.currentTime)
            if let previous = samples.last {
                #expect(sample.audio >= previous.audio - 0.1)
                #expect(sample.audio <= sample.time - startedAt + 0.35)
            }
            samples.append(sample)
            if visited.last != player.currentClipIndex { visited.append(player.currentClipIndex) }
            if visited.last == 3, !player.isPlaying, endedFiles.withLock({ $0.count }) == 4 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(endedFiles.withLock { $0 } == Set((0..<4).map { "chapter-\($0).wav" }))
        #expect(visited.first == 0)
        #expect(visited.last == 3)
        #expect(zip(visited, visited.dropFirst()).allSatisfy { $0.0 < $0.1 })
        #expect(!player.isPlaying)
    }

    @Test(arguments: [false, true])
    func naturalPlaybackHandlesChaptersAcrossSharedAndSplitAudioFiles(pauseAtBoundary: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let durations = ["first.wav": 1.0, "shared.wav": 3.0, "last.wav": 2.0]
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        for (name, duration) in durations {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(duration * 8_000)))
            buffer.frameLength = buffer.frameCapacity
            try #require(buffer.floatChannelData?[0]).update(repeating: 0, count: Int(buffer.frameLength))
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: format.settings)
            try file.write(from: buffer)
        }
        let layout: [(Int, String, Double, Double)] = [
            (0, "first.wav", 0, 1), (0, "shared.wav", 0, 1),
            (1, "shared.wav", 1, 2), (2, "shared.wav", 2, 3),
            (2, "last.wav", 0, 1), (3, "last.wav", 1, 2),
        ]
        let clips = layout.enumerated().map { index, item in
            AudioOverlayClip(fragmentId: "clip-\(index)", textHref: "chapter-\(item.0).xhtml",
                             audioSrc: item.1, clipBegin: item.2, clipEnd: item.3)
        }
        let suiteName = "MediaOverlayPlayerPositionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = MediaOverlayPlayer(defaults: defaults)
        player.skipSkippables = false
        player.playbackRate = 1
        player.load(clips: clips, timeline: MediaOverlayTimeline(clips: clips, audioDurationsBySource: durations),
                    audioDir: directory)
        defer { player.cleanup() }
        let startedAt = ProcessInfo.processInfo.systemUptime
        player.play()
        var visited: [Int] = []
        var samples: [(time: TimeInterval, audio: TimeInterval, clip: Int)] = []
        var paused = false
        var pausedDuration: TimeInterval = 0
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            player.refreshPositionFromPlayhead()
            let sample = (time: ProcessInfo.processInfo.systemUptime, audio: player.currentTime, clip: player.currentClipIndex)
            if let previous = samples.last {
                let elapsed = sample.time - previous.time
                #expect(sample.audio >= previous.audio - 0.1, "Recent samples: \(samples.suffix(4)) → \(sample)")
                #expect(sample.audio <= sample.time - startedAt - pausedDuration + 0.35,
                    "Recent samples: \(samples.suffix(4)) → \(sample)")
                if sample.clip > previous.clip + 1 { #expect(elapsed >= 0.8) }
            }
            samples.append(sample)
            if visited.last != sample.clip { visited.append(sample.clip) }
            if pauseAtBoundary, !paused, sample.clip >= 2 {
                paused = true
                player.remotePause()
                let pauseStartedAt = ProcessInfo.processInfo.systemUptime
                let pausedTime = player.currentTime
                try await Task.sleep(for: .milliseconds(300))
                player.refreshPositionFromPlayhead()
                #expect(player.currentClipIndex == sample.clip)
                #expect(abs(player.currentTime - pausedTime) < 0.1)
                pausedDuration += ProcessInfo.processInfo.systemUptime - pauseStartedAt
                player.remotePlay()
            }
            if visited.last == 5, !player.isPlaying { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!pauseAtBoundary || paused)
        #expect(visited.first == 0)
        #expect(visited.last == 5)
        #expect(zip(visited, visited.dropFirst()).allSatisfy { $0.0 < $0.1 })
        #expect(!player.isPlaying)
    }

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
        let suiteName = "MediaOverlayPlayerPositionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = MediaOverlayPlayer(defaults: defaults)
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
        let pausedAt = player.currentTime
        try await Task.sleep(for: .milliseconds(300))
        player.refreshPositionFromPlayhead()
        #expect(!player.isPlaying)
        #expect(abs(player.currentTime - pausedAt) < 0.1)
    }
}
