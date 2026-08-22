import AVFoundation
import Combine
import Foundation
import UIKit
import Zip

@MainActor
final class TVStorytellerAudioPlayer: NSObject, ObservableObject {

    @Published var currentFragmentId: String?
    @Published var isPlaying: Bool = false
    @Published var playbackRate: Double = 1.0

    private var clips: [TVAudioOverlayClip] = []
    private var clipIndex: [String: Int] = [:]
    private var audioDir: URL?
    private var currentClipIdx: Int = 0

    private var player: AVQueuePlayer?
    private var boundaryObserver: Any?
    private var currentItemObservation: NSKeyValueObservation?

    private var audioFileGroups: [(audioSrc: String, startIdx: Int, endIdx: Int)] = []
    private var clipToGroupIdx: [Int] = []
    private var groupItems: [AVPlayerItem?] = []
    private var itemToGroup: [ObjectIdentifier: Int] = [:]

    func load(clips: [TVAudioOverlayClip], audioDir: URL) {
        self.clips = clips
        self.audioDir = audioDir
        self.clipIndex = Dictionary(
            clips.enumerated().map { ($1.fragmentId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        currentClipIdx = 0
        currentFragmentId = clips.first?.fragmentId
        buildAudioFileGroups()
        buildQueue(startingAtGroup: 0)
    }

    func play(fromFragment fragmentId: String? = nil) {
        if let frag = fragmentId, let idx = clipIndex[frag] {
            currentClipIdx = idx
        }
        activateAudioSession()
        startPlayback()
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        guard player != nil else { return }
        activateAudioSession()
        isPlaying = true
        applyRate()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func next() {
        guard currentClipIdx + 1 < clips.count else { stop(); return }
        currentClipIdx += 1
        if isPlaying {
            startPlayback()
        } else {
            seekToCurrentClip()
            currentFragmentId = clips[currentClipIdx].fragmentId
        }
    }

    func previous() {
        guard currentClipIdx > 0 else { return }
        currentClipIdx -= 1
        if isPlaying {
            startPlayback()
        } else {
            seekToCurrentClip()
            currentFragmentId = clips[currentClipIdx].fragmentId
        }
    }

    func setRate(_ rate: Double) {
        playbackRate = min(max(rate, 0.5), 3.0)
        applyRate()
    }

    func stop() {
        teardownObservers()
        player?.pause()
        player = nil
        isPlaying = false
    }

    func cleanup() {
        stop()
        deactivateAudioSession()
        clips = []
        clipIndex = [:]
        audioDir = nil
        currentFragmentId = nil
        audioFileGroups = []
        clipToGroupIdx = []
        groupItems = []
        itemToGroup = [:]
    }

    private func buildAudioFileGroups() {
        audioFileGroups = []
        clipToGroupIdx = Array(repeating: 0, count: clips.count)
        guard !clips.isEmpty else { return }

        var groupStart = 0
        var currentSrc = clips[0].audioSrc

        for i in 1..<clips.count {
            if clips[i].audioSrc != currentSrc {
                let groupIdx = audioFileGroups.count
                audioFileGroups.append((audioSrc: currentSrc, startIdx: groupStart, endIdx: i - 1))
                for j in groupStart...(i - 1) { clipToGroupIdx[j] = groupIdx }
                groupStart = i
                currentSrc = clips[i].audioSrc
            }
        }
        let groupIdx = audioFileGroups.count
        audioFileGroups.append((audioSrc: currentSrc, startIdx: groupStart, endIdx: clips.count - 1))
        for j in groupStart...(clips.count - 1) { clipToGroupIdx[j] = groupIdx }
    }

    private func buildQueue(startingAtGroup startingGroup: Int) {
        teardownObservers()
        guard let audioDir, !audioFileGroups.isEmpty else {
            player = nil
            return
        }

        groupItems = Array(repeating: nil, count: audioFileGroups.count)
        itemToGroup = [:]
        var items: [AVPlayerItem] = []

        for groupIdx in startingGroup..<audioFileGroups.count {
            let group = audioFileGroups[groupIdx]
            let fileURL = audioDir.appendingPathComponent(TVStorytellerPaths.localAudioFilename(for: group.audioSrc))
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let item = AVPlayerItem(asset: AVURLAsset(url: fileURL))
            item.audioTimePitchAlgorithm = .timeDomain
            groupItems[groupIdx] = item
            itemToGroup[ObjectIdentifier(item)] = groupIdx
            items.append(item)
        }

        guard !items.isEmpty else { player = nil; return }

        let queue = AVQueuePlayer(items: items)
        queue.actionAtItemEnd = .advance
        queue.automaticallyWaitsToMinimizeStalling = false
        player = queue
        observeCurrentItem()
    }

    private func startPlayback() {
        guard currentClipIdx < clips.count, audioDir != nil else { stop(); return }
        let targetGroup = clipToGroupIdx[currentClipIdx]

        if currentGroupIndex() != targetGroup || player == nil {
            buildQueue(startingAtGroup: targetGroup)
        }
        guard player != nil else { return }

        currentFragmentId = clips[currentClipIdx].fragmentId
        seekToCurrentClip()
        isPlaying = true
        applyRate()
        reinstallBoundaryObserver()
    }

    private func seekToCurrentClip() {
        guard let player, currentClipIdx < clips.count else { return }
        let time = CMTime(seconds: clips[currentClipIdx].clipBegin, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func currentGroupIndex() -> Int? {
        guard let item = player?.currentItem else { return nil }
        return itemToGroup[ObjectIdentifier(item)]
    }

    private func applyRate() {
        player?.rate = isPlaying ? Float(playbackRate) : 0
    }

    private func reinstallBoundaryObserver() {
        guard let player else { return }
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
        guard let groupIdx = currentGroupIndex() else { return }
        let group = audioFileGroups[groupIdx]
        guard group.startIdx < group.endIdx else { return }

        var times: [NSValue] = []
        for idx in group.startIdx..<group.endIdx {
            let boundary = max(0, clips[idx].clipEnd)
            times.append(NSValue(time: CMTime(seconds: boundary, preferredTimescale: 600)))
        }
        guard !times.isEmpty else { return }

        boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.boundaryCrossed() }
        }
    }

    private func boundaryCrossed() {
        guard isPlaying, currentClipIdx + 1 < clips.count else { return }
        let nextIdx = currentClipIdx + 1
        guard clipToGroupIdx[nextIdx] == clipToGroupIdx[currentClipIdx] else { return }
        currentClipIdx = nextIdx
        currentFragmentId = clips[currentClipIdx].fragmentId
    }

    private func observeCurrentItem() {
        currentItemObservation = player?.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.currentItemChanged() }
        }
    }

    private func currentItemChanged() {
        guard let groupIdx = currentGroupIndex() else {
            if isPlaying { stop() }
            return
        }
        let group = audioFileGroups[groupIdx]
        if currentClipIdx < group.startIdx || currentClipIdx > group.endIdx {
            currentClipIdx = group.startIdx
            currentFragmentId = clips[currentClipIdx].fragmentId
        }
        applyRate()
        reinstallBoundaryObserver()
    }

    private func teardownObservers() {
        if let boundaryObserver { player?.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        currentItemObservation?.invalidate()
        currentItemObservation = nil
    }

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {

        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct TVStorytellerTextSegment: Hashable, Identifiable {
    let id: Int
    let fragmentId: String?
    let text: String
}

struct TVStorytellerChapter: Hashable, Identifiable {
    let id: Int
    let title: String
    let href: String
    let segments: [TVStorytellerTextSegment]
}

struct TVStorytellerBook {
    let chapters: [TVStorytellerChapter]
    let clips: [TVAudioOverlayClip]
    let audioDir: URL
}

enum TVStorytellerLoader {
    struct LoadError: Error {
        let message: String
    }

    @MainActor
    static func load(book: Book) async throws -> TVStorytellerBook {
        guard let epubURL = book.ebookFileURL else {
            throw LoadError(message: "This Storyteller book hasn't been downloaded yet. Download it from the Enve iPhone app first.")
        }
        guard FileManager.default.fileExists(atPath: epubURL.path) else {
            throw LoadError(message: "The downloaded book file is missing.")
        }
        let bookId = book.stableId

        return try await Task.detached(priority: .userInitiated) {
            let unzipped = try unzipIfNeeded(epubURL: epubURL, bookId: bookId)
            let opfURL = try locateOPF(in: unzipped)
            let (chapters, spineHrefs) = try parseChaptersWithFragments(opfURL: opfURL)
            let clips = try collectClips(unzippedDir: unzipped, opfURL: opfURL, spineHrefs: spineHrefs)
            guard !clips.isEmpty else {
                throw LoadError(message: "This book has no Storyteller audio alignment.")
            }
            let audioDir = try extractAudioFiles(unzippedDir: unzipped, opfURL: opfURL, clips: clips, bookId: bookId)
            return TVStorytellerBook(chapters: chapters, clips: clips, audioDir: audioDir)
        }.value
    }

    nonisolated private static func unzipIfNeeded(epubURL: URL, bookId: String) throws -> URL {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EnveTV/storyteller", isDirectory: true)
        let bookDir = cacheRoot.appendingPathComponent(bookId, isDirectory: true)
        let containerPath = bookDir.appendingPathComponent("META-INF/container.xml")
        if FileManager.default.fileExists(atPath: containerPath.path) { return bookDir }
        try? FileManager.default.removeItem(at: bookDir)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try Zip.unzipFile(epubURL, destination: bookDir, overwrite: true, password: nil)
        return bookDir
    }

    nonisolated private static func locateOPF(in unzippedDir: URL) throws -> URL {
        let containerURL = unzippedDir.appendingPathComponent("META-INF/container.xml")
        let xml = try String(contentsOf: containerURL, encoding: .utf8)
        guard let fullPath = firstRegexCapture(in: xml, pattern: #"<rootfile\b[^>]*\bfull-path="([^"]+)""#),
            !fullPath.isEmpty
        else {
            throw LoadError(message: "This book's structure is missing a rootfile entry.")
        }
        return unzippedDir.appendingPathComponent(fullPath)
    }

    nonisolated private static func parseChaptersWithFragments(opfURL: URL) throws -> ([TVStorytellerChapter], [String]) {
        let opfDir = opfURL.deletingLastPathComponent()
        let opfXML = try String(contentsOf: opfURL, encoding: .utf8)

        var hrefForId: [String: String] = [:]
        for match in allRegexMatches(in: opfXML, pattern: #"<item\b([^>]*)/?>"#) {
            guard let id = firstRegexCapture(in: match, pattern: #"\bid="([^"]+)""#),
                let href = firstRegexCapture(in: match, pattern: #"\bhref="([^"]+)""#)
            else { continue }
            hrefForId[id] = href
        }

        var spineOrder: [String] = []
        for match in allRegexMatches(in: opfXML, pattern: #"<itemref\b([^>]*)/?>"#) {
            if let idref = firstRegexCapture(in: match, pattern: #"\bidref="([^"]+)""#) {
                spineOrder.append(idref)
            }
        }

        var chapters: [TVStorytellerChapter] = []
        var spineHrefs: [String] = []
        var segmentCounter = 0

        for (chapterIdx, idref) in spineOrder.enumerated() {
            guard let href = hrefForId[idref] else { continue }
            spineHrefs.append(
                TVStorytellerPaths.normalizeHref(
                    TVStorytellerPaths.resolvePathDots(
                        opfDir.appendingPathComponent(href).path
                            .replacingOccurrences(of: opfDir.deletingLastPathComponent().path + "/", with: "")
                    )
                )
            )
            let chapterURL = opfDir.appendingPathComponent(href)
            guard let html = try? String(contentsOf: chapterURL, encoding: .utf8) else { continue }
            let title = extractTitle(from: html, fallback: "Chapter \(chapters.count + 1)")
            let segments = extractFragmentedText(from: html, counterStart: segmentCounter)
            segmentCounter += segments.count
            guard !segments.isEmpty else { continue }
            chapters.append(
                TVStorytellerChapter(
                    id: chapterIdx,
                    title: title,
                    href: href,
                    segments: segments
                )
            )
        }
        return (chapters, spineHrefs)
    }

    nonisolated private static func extractFragmentedText(from html: String, counterStart: Int) -> [TVStorytellerTextSegment] {
        var body = html
        body = regexReplace(in: body, pattern: #"<script\b[^>]*>[\s\S]*?</script>"#, with: " ")
        body = regexReplace(in: body, pattern: #"<style\b[^>]*>[\s\S]*?</style>"#, with: " ")

        guard let bodyRange = body.range(of: "<body", options: [.caseInsensitive]) else {
            return [makeSegment(id: counterStart, fragmentId: nil, text: plainText(from: body))].filter { !$0.text.isEmpty }
        }
        guard let bodyClose = body.range(of: "</body>", options: [.caseInsensitive], range: bodyRange.upperBound..<body.endIndex) else {
            return [makeSegment(id: counterStart, fragmentId: nil, text: plainText(from: String(body[bodyRange.upperBound...])))].filter {
                !$0.text.isEmpty
            }
        }
        let bodyInner = String(body[bodyRange.upperBound..<bodyClose.lowerBound])

        let pattern = #"<[a-zA-Z][^>]*\bid="([^"]+)"[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return [makeSegment(id: counterStart, fragmentId: nil, text: plainText(from: bodyInner))].filter { !$0.text.isEmpty }
        }
        let nsBody = bodyInner as NSString
        let range = NSRange(location: 0, length: nsBody.length)
        let matches = regex.matches(in: bodyInner, options: [], range: range)
        guard !matches.isEmpty else {
            return [makeSegment(id: counterStart, fragmentId: nil, text: plainText(from: bodyInner))].filter { !$0.text.isEmpty }
        }

        var segments: [TVStorytellerTextSegment] = []
        var counter = counterStart
        var cursor = 0

        for (i, match) in matches.enumerated() {

            if match.range.location > cursor {
                let leading = nsBody.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let text = plainText(from: leading)
                if !text.isEmpty {
                    segments.append(makeSegment(id: counter, fragmentId: nil, text: text))
                    counter += 1
                }
            }

            let fragmentId = nsBody.substring(with: match.range(at: 1))
            let segmentStart = match.range.location + match.range.length
            let segmentEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : nsBody.length
            let segmentHTML = nsBody.substring(with: NSRange(location: segmentStart, length: segmentEnd - segmentStart))
            let text = plainText(from: segmentHTML)
            if !text.isEmpty {
                segments.append(makeSegment(id: counter, fragmentId: fragmentId, text: text))
                counter += 1
            }
            cursor = segmentEnd
        }
        return segments
    }

    nonisolated private static func makeSegment(id: Int, fragmentId: String?, text: String) -> TVStorytellerTextSegment {
        TVStorytellerTextSegment(id: id, fragmentId: fragmentId, text: text)
    }

    nonisolated private static func plainText(from html: String) -> String {
        var s = html
        s = regexReplace(in: s, pattern: #"</(p|div|h[1-6]|li|blockquote|br)\s*>"#, with: " ")
        s = regexReplace(in: s, pattern: #"<br\s*/?>"#, with: " ")
        s = regexReplace(in: s, pattern: #"<[^>]+>"#, with: "")
        s = decodeEntities(s)
        s = regexReplace(in: s, pattern: #"\s+"#, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func extractTitle(from html: String, fallback: String) -> String {
        for pattern in [#"<h1\b[^>]*>([\s\S]*?)</h1>"#, #"<h2\b[^>]*>([\s\S]*?)</h2>"#, #"<title\b[^>]*>([\s\S]*?)</title>"#] {
            if let raw = firstRegexCapture(in: html, pattern: pattern) {
                let text = decodeEntities(regexReplace(in: raw, pattern: #"<[^>]+>"#, with: ""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return fallback
    }

    nonisolated private static func decodeEntities(_ s: String) -> String {
        var out = s
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "),
            ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"), ("&hellip;", "…"),
            ("&lsquo;", "‘"), ("&rsquo;", "’"), ("&ldquo;", "“"), ("&rdquo;", "”"),
        ]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    nonisolated private static func collectClips(unzippedDir: URL, opfURL: URL, spineHrefs: [String]) throws -> [TVAudioOverlayClip] {
        var clips: [TVAudioOverlayClip] = []
        let enumerator = FileManager.default.enumerator(at: unzippedDir, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "smil" else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let relPath = url.path.replacingOccurrences(of: unzippedDir.path + "/", with: "")
            let baseHref = TVStorytellerPaths.normalizeHref(TVStorytellerPaths.resolvePathDots(relPath))
            let parser = TVSmilXMLParser(data: data, baseHref: baseHref)
            clips.append(contentsOf: parser.parseAndReturn())
        }
        return sortClipsBySpine(clips, spineHrefs: spineHrefs)
    }

    nonisolated private static func sortClipsBySpine(_ clips: [TVAudioOverlayClip], spineHrefs: [String]) -> [TVAudioOverlayClip] {
        var positions: [String: Int] = [:]
        for (i, href) in spineHrefs.enumerated() {
            positions[TVStorytellerPaths.normalizeHref(href)] = i
        }
        func position(for textHref: String) -> Int {
            let n = TVStorytellerPaths.normalizeHref(textHref)
            if let p = positions[n] { return p }
            for (k, v) in positions where k.hasSuffix(n) || n.hasSuffix(k) { return v }
            return Int.max
        }
        return clips.enumerated()
            .sorted { a, b in
                let pa = position(for: a.element.textHref)
                let pb = position(for: b.element.textHref)
                if pa != pb { return pa < pb }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    nonisolated private static func extractAudioFiles(
        unzippedDir: URL,
        opfURL: URL,
        clips: [TVAudioOverlayClip],
        bookId: String
    ) throws -> URL {
        let audioDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-tv-storyteller").appendingPathComponent(bookId)
        if FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.removeItem(at: audioDir)
        }
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let opfDir = opfURL.deletingLastPathComponent()
        let uniqueSrcs = Array(Set(clips.map(\.audioSrc)))

        for src in uniqueSrcs {
            let cleaned = TVStorytellerPaths.resolvePathDots(src)
            let candidateRelative = opfDir.appendingPathComponent(cleaned)
            let dest = audioDir.appendingPathComponent(TVStorytellerPaths.localAudioFilename(for: src))

            if FileManager.default.fileExists(atPath: candidateRelative.path) {
                try? FileManager.default.copyItem(at: candidateRelative, to: dest)
                continue
            }

            if let found = findAudioFile(named: (cleaned as NSString).lastPathComponent, in: unzippedDir) {
                try? FileManager.default.copyItem(at: found, to: dest)
            }
        }
        return audioDir
    }

    nonisolated private static func findAudioFile(named filename: String, in root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.lowercased() == filename.lowercased() { return url }
        }
        return nil
    }

    nonisolated private static func firstRegexCapture(in source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: range),
            match.numberOfRanges >= 2,
            let captureRange = Range(match.range(at: 1), in: source)
        else { return nil }
        return String(source[captureRange])
    }

    nonisolated private static func allRegexMatches(in source: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, options: [], range: range).compactMap { match in
            guard let r = Range(match.range, in: source) else { return nil }
            return String(source[r])
        }
    }

    nonisolated private static func regexReplace(in source: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.stringByReplacingMatches(in: source, options: [], range: range, withTemplate: replacement)
    }
}
