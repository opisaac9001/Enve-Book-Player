import AVFoundation
import Foundation

#if os(iOS)
struct MediaOverlayTimeline: Sendable {
    struct AudioFile: Sendable {
        let source: String
        let start: TimeInterval
        let duration: TimeInterval

        var end: TimeInterval { start + duration }
    }

    struct ClipTiming: Sendable {
        let audioStart: TimeInterval
        let audioEnd: TimeInterval
        let spokenStart: TimeInterval
        let spokenEnd: TimeInterval
    }

    struct ResolvedPosition: Sendable {
        enum Source: Sendable {
            case fragment
            case progression
        }

        let clipIndex: Int
        let audioTime: TimeInterval
        let source: Source
    }

    let clips: [AudioOverlayClip]
    let audioFiles: [AudioFile]
    let clipTimings: [ClipTiming]
    let totalAudioDuration: TimeInterval
    let totalSpokenDuration: TimeInterval

    private let audioFileIndexBySource: [String: Int]
    private let clipIndicesByFragment: [String: [Int]]
    private let clipIndicesByAudioStart: [Int]

    init(
        clips: [AudioOverlayClip],
        audioDurationsBySource: [String: TimeInterval] = [:],
        orderedAudioDurations: [TimeInterval] = []
    ) {
        self.clips = clips

        var orderedSources: [String] = []
        var seenSources = Set<String>()
        var maximumClipEndBySource: [String: TimeInterval] = [:]
        for clip in clips {
            if seenSources.insert(clip.audioSrc).inserted {
                orderedSources.append(clip.audioSrc)
            }
            maximumClipEndBySource[clip.audioSrc] = max(
                maximumClipEndBySource[clip.audioSrc] ?? 0,
                clip.clipEnd
            )
        }

        var files: [AudioFile] = []
        var fileIndex: [String: Int] = [:]
        var audioOffset: TimeInterval = 0
        for (index, source) in orderedSources.enumerated() {
            let measuredDuration =
                audioDurationsBySource[source]
                ?? (orderedAudioDurations.indices.contains(index) ? orderedAudioDurations[index] : nil)
                ?? 0
            let duration = max(measuredDuration, maximumClipEndBySource[source] ?? 0)
            fileIndex[source] = files.count
            files.append(AudioFile(source: source, start: audioOffset, duration: duration))
            audioOffset += duration
        }

        var spokenOffset: TimeInterval = 0
        var timings: [ClipTiming] = []
        for clip in clips {
            let fileStart = fileIndex[clip.audioSrc].map { files[$0].start } ?? 0
            let duration = max(0, clip.duration)
            timings.append(
                ClipTiming(
                    audioStart: fileStart + clip.clipBegin,
                    audioEnd: fileStart + clip.clipEnd,
                    spokenStart: spokenOffset,
                    spokenEnd: spokenOffset + duration
                )
            )
            spokenOffset += duration
        }

        audioFiles = files
        audioFileIndexBySource = fileIndex
        clipTimings = timings
        totalAudioDuration = audioOffset
        totalSpokenDuration = spokenOffset
        clipIndicesByFragment = Dictionary(grouping: clips.indices, by: { clips[$0].fragmentId })
        clipIndicesByAudioStart = clips.indices.sorted {
            if timings[$0].audioStart == timings[$1].audioStart {
                return $0 < $1
            }
            return timings[$0].audioStart < timings[$1].audioStart
        }
    }

    static func measuredAudioDurations(
        clips: [AudioOverlayClip],
        audioDirectory: URL
    ) async -> [String: TimeInterval] {
        var durations: [String: TimeInterval] = [:]
        var seenSources = Set<String>()

        for clip in clips where seenSources.insert(clip.audioSrc).inserted {
            let url = EPUB3SMILParser.localAudioURL(for: clip.audioSrc, in: audioDirectory)
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { continue }
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                durations[clip.audioSrc] = seconds
            }
        }

        return durations
    }

    func duration(forAudioSource source: String) -> TimeInterval? {
        audioFileIndexBySource[source].map { audioFiles[$0].duration }
    }

    func audioStart(forAudioSource source: String) -> TimeInterval? {
        audioFileIndexBySource[source].map { audioFiles[$0].start }
    }

    func audioTime(forClipIndex clipIndex: Int) -> TimeInterval? {
        guard clipTimings.indices.contains(clipIndex) else { return nil }
        return clipTimings[clipIndex].audioStart
    }

    func clipIndex(fragmentId: String, preferredHref: String?) -> Int? {
        guard let candidates = clipIndicesByFragment[fragmentId], !candidates.isEmpty else {
            return nil
        }
        if let preferredHref,
            let match = candidates.first(where: { Self.hrefMatches(clips[$0].textHref, preferredHref) })
        {
            return match
        }
        return candidates[0]
    }

    func clipIndex(atAudioTime time: TimeInterval) -> Int? {
        guard !clipIndicesByAudioStart.isEmpty else { return nil }
        let clampedTime = min(max(time, 0), totalAudioDuration)

        var lowerBound = 0
        var upperBound = clipIndicesByAudioStart.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            let clipIndex = clipIndicesByAudioStart[middle]
            if clipTimings[clipIndex].audioStart <= clampedTime {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        if lowerBound == 0 {
            return clipIndicesByAudioStart[0]
        }
        let previousIndex = clipIndicesByAudioStart[lowerBound - 1]
        guard lowerBound < clipIndicesByAudioStart.count else { return previousIndex }

        let nextIndex = clipIndicesByAudioStart[lowerBound]
        let previous = clips[previousIndex]
        let next = clips[nextIndex]
        if previous.audioSrc == next.audioSrc,
            clampedTime >= clipTimings[previousIndex].audioEnd,
            clampedTime < clipTimings[nextIndex].audioStart
        {
            return nextIndex
        }
        return previousIndex
    }

    func clipIndex(atSpokenProgression progression: Double) -> Int? {
        guard !clips.isEmpty else { return nil }
        guard totalSpokenDuration > 0 else {
            let bounded = min(max(progression, 0), 0.999_999)
            return min(Int(bounded * Double(clips.count)), clips.count - 1)
        }

        let target = min(max(progression, 0), 1) * totalSpokenDuration
        return clipTimings.firstIndex(where: { $0.spokenEnd >= target }) ?? clipTimings.indices.last
    }

    func spokenElapsed(atAudioTime time: TimeInterval, clipIndex preferredClipIndex: Int? = nil) -> TimeInterval {
        guard let clipIndex = preferredClipIndex ?? clipIndex(atAudioTime: time),
            clips.indices.contains(clipIndex)
        else { return 0 }
        let clip = clips[clipIndex]
        let timing = clipTimings[clipIndex]
        guard let fileStart = audioStart(forAudioSource: clip.audioSrc) else { return timing.spokenStart }
        let localTime = min(max(time - fileStart, clip.clipBegin), clip.clipEnd)
        return timing.spokenStart + max(0, localTime - clip.clipBegin)
    }

    func spokenProgression(atAudioTime time: TimeInterval, clipIndex: Int? = nil) -> Double {
        guard totalSpokenDuration > 0 else { return 0 }
        return min(max(spokenElapsed(atAudioTime: time, clipIndex: clipIndex) / totalSpokenDuration, 0), 1)
    }

    func chapterProgression(atAudioTime time: TimeInterval, clipIndex: Int) -> Double {
        guard clips.indices.contains(clipIndex) else { return 0 }
        let href = clips[clipIndex].textHref
        let chapterIndices = clips.indices.filter { Self.hrefMatches(clips[$0].textHref, href) }
        let chapterDuration = chapterIndices.reduce(0) { $0 + max(0, clips[$1].duration) }
        guard chapterDuration > 0 else { return 0 }

        var elapsed: TimeInterval = 0
        for index in chapterIndices {
            if index == clipIndex {
                let clip = clips[index]
                guard let fileStart = audioStart(forAudioSource: clip.audioSrc) else { break }
                let localTime = min(max(time - fileStart, clip.clipBegin), clip.clipEnd)
                elapsed += max(0, localTime - clip.clipBegin)
                break
            }
            elapsed += max(0, clips[index].duration)
        }
        return min(max(elapsed / chapterDuration, 0), 1)
    }

    func resolveEPUB3Locator(locatorJSON: String) -> ResolvedPosition? {
        guard let data = locatorJSON.data(using: .utf8),
            let locator = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let locations = locator["locations"] as? [String: Any]
        else { return nil }

        let href = locator["href"] as? String
        let type = (locator["type"] as? String)?.lowercased() ?? ""
        let fragments = Self.fragments(in: locations)
        let isAudioLocator =
            type.contains("audio")
            || href?.lowercased().hasPrefix("audiobook://") == true

        if isAudioLocator {
            let progression = Self.doubleValue(locations["totalProgression"]) ?? 0
            guard let clipIndex = clipIndex(atSpokenProgression: progression),
                let audioTime = audioTime(forClipIndex: clipIndex)
            else { return nil }
            return ResolvedPosition(
                clipIndex: clipIndex,
                audioTime: audioTime,
                source: .progression
            )
        }

        if let fragment = fragments.first(where: {
            !$0.hasPrefix("t=") && !$0.hasPrefix("epubcfi(")
        }), let clipIndex = clipIndex(fragmentId: fragment, preferredHref: href),
            let audioTime = audioTime(forClipIndex: clipIndex)
        {
            return ResolvedPosition(clipIndex: clipIndex, audioTime: audioTime, source: .fragment)
        }

        if let href,
            let progression = Self.doubleValue(locations["progression"]),
            let clipIndex = clipIndex(atChapterProgression: progression, href: href),
            let audioTime = audioTime(forClipIndex: clipIndex)
        {
            return ResolvedPosition(clipIndex: clipIndex, audioTime: audioTime, source: .progression)
        }

        if let progression = Self.doubleValue(locations["totalProgression"]),
            let clipIndex = clipIndex(atSpokenProgression: progression),
            let audioTime = audioTime(forClipIndex: clipIndex)
        {
            return ResolvedPosition(clipIndex: clipIndex, audioTime: audioTime, source: .progression)
        }

        return nil
    }

    func clipIndex(atChapterProgression progression: Double, href: String) -> Int? {
        let chapterIndices = clips.indices.filter { Self.hrefMatches(clips[$0].textHref, href) }
        guard !chapterIndices.isEmpty else { return nil }

        let chapterDuration = chapterIndices.reduce(0) { $0 + max(0, clips[$1].duration) }
        guard chapterDuration > 0 else { return chapterIndices.first }

        let target = min(max(progression, 0), 1) * chapterDuration
        var elapsed: TimeInterval = 0
        for index in chapterIndices {
            elapsed += max(0, clips[index].duration)
            if elapsed >= target {
                return index
            }
        }
        return chapterIndices.last
    }

    func textLocatorJSONString(
        clipIndex: Int,
        audioTime: TimeInterval,
        totalProgression: Double? = nil
    ) -> String? {
        guard clips.indices.contains(clipIndex) else { return nil }
        let clip = clips[clipIndex]
        let clampedAudioTime = min(max(audioTime, 0), totalAudioDuration)
        let locator: [String: Any] = [
            "href": clip.textHref,
            "type": "application/xhtml+xml",
            "locations": [
                "fragments": [clip.fragmentId],
                "progression": chapterProgression(atAudioTime: clampedAudioTime, clipIndex: clipIndex),
                "totalProgression": min(
                    max(
                        totalProgression
                            ?? spokenProgression(
                                atAudioTime: clampedAudioTime,
                                clipIndex: clipIndex
                            ),
                        0
                    ),
                    1
                ),
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: locator) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func audioFilePosition(atAudioTime audioTime: TimeInterval) -> (file: AudioFile, localTime: TimeInterval)? {
        guard let file = audioFile(atAudioTime: audioTime) else { return nil }
        let localTime = min(max(audioTime - file.start, 0), file.duration)
        return (file, localTime)
    }

    private func audioFile(atAudioTime audioTime: TimeInterval) -> AudioFile? {
        guard !audioFiles.isEmpty else { return nil }
        let clampedTime = min(max(audioTime, 0), totalAudioDuration)
        return audioFiles.first(where: { clampedTime < $0.end }) ?? audioFiles.last
    }

    private static func fragments(in locations: [String: Any]) -> [String] {
        if let fragments = locations["fragments"] as? [String] {
            return fragments
        }
        if let fragments = locations["fragments"] as? [Any] {
            return fragments.compactMap { $0 as? String }
        }
        return []
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func hrefMatches(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizedHref(lhs)
        let b = normalizedHref(rhs)
        guard !a.isEmpty, !b.isEmpty else { return a == b }
        if a == b || a.hasSuffix(b) || b.hasSuffix(a) { return true }
        let fileA = (a as NSString).lastPathComponent
        let fileB = (b as NSString).lastPathComponent
        return !fileA.isEmpty && fileA == fileB
    }

    private static func normalizedHref(_ href: String) -> String {
        let withoutFragment =
            href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? href
        let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
        return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }
}
#endif
