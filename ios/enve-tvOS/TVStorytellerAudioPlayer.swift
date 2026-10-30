import AVFoundation
import Combine
import Foundation
import UIKit
import Zip

@MainActor
final class TVStorytellerAudioPlayer: NSObject, ObservableObject {
    @Published private(set) var currentClipIndex = 0
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var playbackError: String?

    var currentClip: TVAudioOverlayClip? {
        timeline.clips.indices.contains(currentClipIndex) ? timeline.clips[currentClipIndex] : nil
    }
    var duration: TimeInterval { timeline.duration }

    private var timeline = TVStorytellerTimeline(clips: [])
    private var audioDir: URL?
    private var player: AVQueuePlayer?
    private var boundaryObserver: Any?
    private var periodicObserver: Any?
    private var currentItemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var observedItem: AVPlayerItem?
    private var itemGroups: [ObjectIdentifier: Int] = [:]
    private var queuedItems: [Int: AVPlayerItem] = [:]
    private var queueID = UUID()
    private var seekID = UUID()
    private var isSeeking = false
    private var previousIdleTimerSetting: Bool?
    private var bookID: String?
    private var lastSavedAt = Date.distantPast

    func load(clips: [TVAudioOverlayClip], audioDir: URL) {
        cleanup()
        timeline = TVStorytellerTimeline(clips: clips)
        self.audioDir = audioDir
        currentClipIndex = 0
        elapsedTime = 0
        playbackError = nil
        previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        seek(toClipAt: 0)
    }

    func play() { resume() }

    func restorePosition(for book: Book) {
        bookID = book.stableId
        var remoteIndex: Int?
        if let locator = book.epubLocator?.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: locator) as? [String: Any],
            let href = json["href"] as? String,
            let locations = json["locations"] as? [String: Any],
            let fragments = locations["fragments"] as? [String]
        {
            remoteIndex = timeline.clips.firstIndex(where: {
                TVStorytellerPaths.normalizeHref($0.textHref) == TVStorytellerPaths.normalizeHref(href)
                    && fragments.contains($0.fragmentId)
            })
        }
        if let saved = TVReadAlongProgressStore.shared.position(for: book.stableId),
            remoteIndex == nil || saved.observedAt >= book.lastUpdate,
            let index = timeline.clips.firstIndex(where: {
                TVStorytellerPaths.normalizeHref($0.textHref) == saved.href && $0.fragmentId == saved.fragmentID
            })
        {
            seek(toClipAt: index, offset: min(max(saved.offset, 0), max(0, timeline.clips[index].duration - 0.01)))
            return
        }
        if let remoteIndex { seek(toClipAt: remoteIndex) }
    }

    func pause() {
        synchronizePosition()
        saveProgress()
        isPlaying = false
        player?.pause()
    }

    func resume() {
        guard !timeline.clips.isEmpty else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            playbackError = "The audio session could not start. Try playing again."
            return
        }
        let needsRecovery = playbackError != nil
        playbackError = nil
        isPlaying = true
        if elapsedTime >= duration {
            seek(toClipAt: 0)
        } else if player?.currentItem == nil || needsRecovery {
            seek(to: elapsedTime)
        } else {
            applyRate()
        }
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func next() {
        guard currentClipIndex + 1 < timeline.clips.count else { return }
        seek(toClipAt: currentClipIndex + 1)
    }

    func previous() {
        seek(toClipAt: max(0, currentClipIndex - 1))
    }

    func setRate(_ rate: Double) {
        playbackRate = min(max(rate, 0.5), 3)
        applyRate()
    }

    func skip(by interval: TimeInterval) {
        seek(to: elapsedTime + interval)
    }

    func seek(to time: TimeInterval) {
        let target = min(max(time, 0), max(0, duration - 0.01))
        guard let index = timeline.clipIndex(at: target) else { return }
        seek(toClipAt: index, offset: target - timeline.starts[index])
    }

    func seek(toClipAt index: Int) {
        seek(toClipAt: index, offset: 0)
    }

    func cleanup() {
        saveProgress()
        isPlaying = false
        teardownQueue()
        if let previousIdleTimerSetting {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting
            self.previousIdleTimerSetting = nil
        }
        if audioDir != nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        timeline = TVStorytellerTimeline(clips: [])
        audioDir = nil
        elapsedTime = 0
        currentClipIndex = 0
        playbackError = nil
        bookID = nil
    }

    private func seek(toClipAt index: Int, offset: TimeInterval) {
        guard timeline.clips.indices.contains(index) else { return }
        playbackError = nil
        let clip = timeline.clips[index]
        currentClipIndex = index
        elapsedTime = timeline.starts[index] + offset
        saveProgress()
        isSeeking = true
        let groupIndex = timeline.groupIndices[index]
        if currentGroupIndex != groupIndex || player?.currentItem?.status == .failed || player?.status == .failed {
            buildQueue(startingAtGroup: groupIndex)
        }
        guard let player, player.currentItem != nil else {
            isSeeking = false
            isPlaying = false
            return
        }
        guard currentGroupIndex == groupIndex else {
            handlePlaybackFailure("The narration could not be played. Try opening the book again.")
            return
        }
        let requestID = UUID()
        seekID = requestID
        player.pause()
        let time = CMTime(seconds: clip.clipBegin + offset, preferredTimescale: 48_000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.seekID == requestID else { return }
                self.isSeeking = false
                guard finished else {
                    self.handlePlaybackFailure("The narration could not seek to this passage. Try playing again.")
                    return
                }
                self.synchronizePosition()
                self.applyRate()
            }
        }
    }

    private var currentGroupIndex: Int? {
        guard let item = player?.currentItem else { return nil }
        return itemGroups[ObjectIdentifier(item)]
    }

    private func buildQueue(startingAtGroup startingGroup: Int) {
        teardownQueue()
        guard let audioDir else { return }
        var items: [AVPlayerItem] = []
        for groupIndex in startingGroup..<timeline.groups.count {
            let group = timeline.groups[groupIndex]
            let url = audioDir.appendingPathComponent(group.audioSrc)
            guard FileManager.default.fileExists(atPath: url.path) else {
                playbackError = "A narration file is missing. Download the complete read-aloud book and try again."
                return
            }
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .timeDomain
            item.forwardPlaybackEndTime = CMTime(
                seconds: timeline.clips[group.clipRange.upperBound - 1].clipEnd,
                preferredTimescale: 48_000
            )
            itemGroups[ObjectIdentifier(item)] = groupIndex
            queuedItems[groupIndex] = item
            items.append(item)
        }
        let queue = AVQueuePlayer(items: items)
        queue.actionAtItemEnd = .advance
        player = queue
        let observedQueueID = queueID
        currentItemObservation = queue.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.queueID == observedQueueID else { return }
                self.currentItemChanged()
            }
        }
        periodicObserver = queue.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizePosition() }
        }
        observeCurrentItem()
    }

    private func currentItemChanged() {
        let failedGroup = queuedItems.keys.sorted().first {
            $0 <= (currentGroupIndex ?? Int.max) && queuedItems[$0]?.status == .failed
        }
        if let failedGroup {
            if timeline.groupIndices[currentClipIndex] != failedGroup {
                currentClipIndex = timeline.groups[failedGroup].clipRange.lowerBound
                elapsedTime = timeline.starts[currentClipIndex]
            }
            handlePlaybackFailure("The narration could not be played. Try opening the book again.")
            return
        }
        guard observedItem?.status != .failed, player?.currentItem?.status != .failed else {
            handlePlaybackFailure("The narration could not be played. Try opening the book again.")
            return
        }
        guard let groupIndex = currentGroupIndex else {
            elapsedTime = duration
            currentClipIndex = max(0, timeline.clips.count - 1)
            isPlaying = false
            isSeeking = false
            return
        }
        observeCurrentItem()
        seek(toClipAt: timeline.groups[groupIndex].clipRange.lowerBound)
    }

    private func observeCurrentItem() {
        statusObservation?.invalidate()
        observedItem = player?.currentItem
        let observedQueueID = queueID
        statusObservation = observedItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let itemID = ObjectIdentifier(item)
            Task { @MainActor [weak self] in
                guard let self, self.queueID == observedQueueID,
                    self.itemGroups[itemID] != nil, failed
                else { return }
                self.handlePlaybackFailure("The narration could not be played. Try opening the book again.")
            }
        }
        installBoundaryObserver()
    }

    private func installBoundaryObserver() {
        guard let player else { return }
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        guard let groupIndex = currentGroupIndex else { return }
        let times = Set(timeline.groups[groupIndex].clipRange.flatMap { index in
            [timeline.clips[index].clipBegin, timeline.clips[index].clipEnd]
        }).sorted().map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 48_000)) }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.synchronizePosition() }
        }
    }

    private func synchronizePosition() {
        guard !isSeeking, playbackError == nil, let player, let groupIndex = currentGroupIndex else { return }
        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        let index = timeline.clipIndex(atAudioTime: time, inGroup: groupIndex)
        currentClipIndex = index
        elapsedTime = timeline.elapsedTime(atAudioTime: time, clipIndex: index)
        if isPlaying, Date().timeIntervalSince(lastSavedAt) >= 15 { saveProgress() }
    }

    private func saveProgress() {
        guard let bookID, let clip = currentClip else { return }
        let now = Date()
        TVReadAlongProgressStore.shared.save(.init(
            href: TVStorytellerPaths.normalizeHref(clip.textHref),
            fragmentID: clip.fragmentId,
            offset: min(max(elapsedTime - timeline.starts[currentClipIndex], 0), clip.duration),
            observedAt: now
        ), for: bookID)
        lastSavedAt = now
    }

    private func applyRate() {
        guard !isSeeking else { return }
        player?.rate = isPlaying ? Float(playbackRate) : 0
    }

    private func handlePlaybackFailure(_ message: String) {
        isSeeking = false
        isPlaying = false
        player?.pause()
        playbackError = message
        saveProgress()
    }

    private func teardownQueue() {
        queueID = UUID()
        seekID = UUID()
        player?.pause()
        if let boundaryObserver { player?.removeTimeObserver(boundaryObserver) }
        if let periodicObserver { player?.removeTimeObserver(periodicObserver) }
        boundaryObserver = nil
        periodicObserver = nil
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        observedItem = nil
        player = nil
        itemGroups = [:]
        queuedItems = [:]
    }
}

nonisolated struct TVStorytellerBook: Sendable {
    let chapters: [TVStorytellerChapter]
    let clips: [TVAudioOverlayClip]
    let audioDir: URL
}

enum TVStorytellerLoader {
    struct LoadError: Error {
        let message: String
    }

    static func load(book: Book) async throws -> TVStorytellerBook {
        let epubURL = try await UnifiedDownloadService.shared.prepareReaderAsset(for: book)
        Zip.addCustomFileExtension(epubURL.pathExtension)
        let bookID = book.stableId
        let task = Task.detached(priority: .userInitiated) {
            let root = try unzipIfNeeded(epubURL: epubURL, bookID: bookID)
            try Task.checkCancellation()
            let container = TVStorytellerPackageParser()
            guard container.parse(try Data(contentsOf: root.appendingPathComponent("META-INF/container.xml"))),
                let rootfile = container.rootfile
            else { throw LoadError(message: "The EPUB is missing its package document.") }
            let opfHref = TVStorytellerPaths.normalizeHref(rootfile)
            let package = TVStorytellerPackageParser()
            guard package.parse(try Data(contentsOf: root.appendingPathComponent(opfHref))) else {
                throw LoadError(message: "The EPUB package could not be read.")
            }
            var documents: [(href: String, overlay: String?)] = []
            for id in package.spine {
                guard let item = package.items[id] else { continue }
                documents.append((
                    TVStorytellerPaths.resolve(item.href, relativeTo: opfHref),
                    item.overlayID.flatMap { package.items[$0] }.map {
                        TVStorytellerPaths.resolve($0.href, relativeTo: opfHref)
                    }
                ))
            }
            var clips: [TVAudioOverlayClip] = []
            var parsedOverlays: Set<String> = []
            for document in documents {
                try Task.checkCancellation()
                guard let overlay = document.overlay, parsedOverlays.insert(overlay).inserted else { continue }
                let data = try Data(contentsOf: root.appendingPathComponent(overlay))
                do {
                    clips.append(contentsOf: try TVSmilXMLParser(data: data, baseHref: overlay).parseAndReturn())
                } catch {
                    throw LoadError(message: "The EPUB's narration alignment is damaged. Download a repaired read-aloud edition or read the text only.")
                }
            }
            let positions = Dictionary(documents.enumerated().map { ($1.href, $0) }, uniquingKeysWith: { first, _ in first })
            clips = clips.enumerated().sorted { a, b in
                let left = positions[a.element.textHref] ?? Int.max
                let right = positions[b.element.textHref] ?? Int.max
                return left == right ? a.offset < b.offset : left < right
            }.map(\.element)
            guard !clips.isEmpty else { throw LoadError(message: "This EPUB has no aligned narration. Choose a read-aloud EPUB with media overlays.") }
            let fragments = Dictionary(grouping: clips, by: \.textHref).mapValues { Set($0.map(\.fragmentId)) }
            var chapters: [TVStorytellerChapter] = []
            var segmentCount = 0
            for (index, document) in documents.enumerated() {
                try Task.checkCancellation()
                let html = try String(contentsOf: root.appendingPathComponent(document.href), encoding: .utf8)
                let parser = TVStorytellerTextParser(fragments: fragments[document.href] ?? [], counterStart: segmentCount)
                guard parser.parse(html) else { throw LoadError(message: "A chapter's text could not be read from this EPUB.") }
                guard !parser.segments.isEmpty else { continue }
                chapters.append(TVStorytellerChapter(
                    id: index, title: parser.title ?? "Chapter \(index + 1)", href: document.href, segments: parser.segments
                ))
                segmentCount += parser.segments.count
            }
            let locations = Set(chapters.flatMap { chapter in
                chapter.segments.compactMap { segment in
                    segment.fragmentId.map { chapter.href + "#" + $0 }
                }
            })
            guard clips.allSatisfy({ locations.contains($0.id) }) else {
                throw LoadError(message: "The narration refers to text missing from this EPUB. Download a complete aligned copy and try again.")
            }
            for source in Set(clips.map(\.audioSrc)) {
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(source).path) else {
                    throw LoadError(message: "The EPUB is missing a narration file. Download the complete read-aloud edition and try again.")
                }
            }
            return TVStorytellerBook(chapters: chapters, clips: clips, audioDir: root)
        }
        return try await withTaskCancellationHandler {
            let loaded = try await task.value
            try Task.checkCancellation()
            return loaded
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func unzipIfNeeded(epubURL: URL, bookID: String) throws -> URL {
        let cacheRoot = URL.cachesDirectory.appendingPathComponent("EnveTV/storyteller", isDirectory: true)
        let bookDir = cacheRoot.appendingPathComponent(bookID, isDirectory: true)
        let values = try epubURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fingerprint = "\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let fingerprintURL = bookDir.appendingPathComponent(".source-fingerprint")
        if (try? String(contentsOf: fingerprintURL, encoding: .utf8)) == fingerprint,
            FileManager.default.fileExists(atPath: bookDir.appendingPathComponent("META-INF/container.xml").path)
        { return bookDir }
        let staging = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try Zip.unzipFile(epubURL, destination: staging, overwrite: true, password: nil)
        try Task.checkCancellation()
        try fingerprint.write(to: staging.appendingPathComponent(".source-fingerprint"), atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: bookDir.path) { try FileManager.default.removeItem(at: bookDir) }
        try FileManager.default.moveItem(at: staging, to: bookDir)
        return bookDir
    }
}
