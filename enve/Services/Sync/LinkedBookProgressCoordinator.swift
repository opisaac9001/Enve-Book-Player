import Foundation

struct LinkedBookCalibrationAnchor: Codable, Equatable, Sendable {
    let ebookProgress: Double
    let audioProgress: Double
    let quote: String
    let href: String?
    let confidence: Double
}

enum LinkedBookQuickSyncError: LocalizedError {
    case emptyEbook
    case downloadFailed
    case downloadTimeout

    var errorDescription: String? {
        switch self {
        case .emptyEbook:
            return "Enve could not find enough readable text in this ebook."
        case .downloadFailed:
            return "The audiobook download failed."
        case .downloadTimeout:
            return "The audiobook download did not finish in time."
        }
    }
}

@MainActor
final class LinkedBookProgressCoordinator {
    static let shared = LinkedBookProgressCoordinator()

    private struct Anchor: Codable, Equatable {
        var ebookProgress: Double
        var audioProgress: Double
        var observedAt: Date
    }

    private struct MappingRecord: Codable {
        var ebookStableId: String
        var audiobookStableId: String
        var chapterProgressions: [Double]
        var chapterLandmarks: [LinkedBookChapterLandmark]?
        var exactAnchors: [Anchor]
        var calibratedAnchors: [LinkedBookCalibrationAnchor]?
    }

    private struct Pair {
        var ebook: Book
        var audiobook: Book

        var key: String {
            "\(ebook.stableId)\u{1F}\(audiobook.stableId)"
        }
    }

    private struct AudioObservation {
        var time: TimeInterval
        var duration: TimeInterval
        var observedAt: Date
        var isFinished: Bool

        var progress: Double {
            guard duration > 0 else { return 0 }
            return Self.clamp(time / duration)
        }

        private static func clamp(_ value: Double) -> Double {
            min(max(value, 0), 1)
        }
    }

    private let defaults: UserDefaults
    private let storageKey = "linkedBookProgressMappings.v1"
    private let propagationInterval: TimeInterval = 4
    private let maximumExactAnchors = 64

    private var mappings: [MappingRecord]
    private var lastPropagation: [String: Date] = [:]

    private let libraryCache: LibraryBookCache
    private let bookRepository: BookStoreRepository

    private init(
        defaults: UserDefaults = .standard,
        libraryCache: LibraryBookCache = AppState.shared.libraryCache,
        bookRepository: BookStoreRepository = AppState.shared.bookStore
    ) {
        self.defaults = defaults
        self.libraryCache = libraryCache
        self.bookRepository = bookRepository
        if let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([MappingRecord].self, from: data)
        {
            mappings = decoded
        } else {
            mappings = []
        }
    }

    func recordChapterLandmarks(
        for book: Book,
        landmarks: [LinkedBookChapterLandmark]
    ) {
        guard let audiobookStableId = book.linkedAudiobookStableId,
            !audiobookStableId.isEmpty
        else { return }

        let ebookStableId = book.readAloudSourceStableId ?? book.stableId
        let normalized =
            landmarks
            .filter { $0.progression.isFinite }
            .map {
                LinkedBookChapterLandmark(
                    title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    progression: Self.clamp($0.progression)
                )
            }
            .sorted { $0.progression < $1.progression }
            .reduce(into: [LinkedBookChapterLandmark]()) { result, landmark in
                guard
                    result.last.map({
                        abs($0.progression - landmark.progression) > 0.0005
                    }) ?? true
                else { return }
                result.append(landmark)
            }
        guard !normalized.isEmpty else { return }

        updateMapping(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId) {
            $0.chapterProgressions = normalized.map(\.progression)
            $0.chapterLandmarks = normalized
        }
    }

    func removeMapping(ebookStableId: String) {
        let previousCount = mappings.count
        mappings.removeAll { $0.ebookStableId == ebookStableId }
        guard mappings.count != previousCount else { return }
        persistMappings()
    }

    func installCalibration(
        ebookStableId: String,
        audiobookStableId: String,
        anchors: [LinkedBookCalibrationAnchor]
    ) {
        let normalized =
            anchors
            .filter {
                $0.ebookProgress.isFinite
                    && $0.audioProgress.isFinite
                    && $0.confidence.isFinite
                    && !$0.quote.isEmpty
            }
            .map {
                LinkedBookCalibrationAnchor(
                    ebookProgress: Self.clamp($0.ebookProgress),
                    audioProgress: Self.clamp($0.audioProgress),
                    quote: $0.quote,
                    href: $0.href,
                    confidence: Self.clamp($0.confidence)
                )
            }
            .sorted { $0.audioProgress < $1.audioProgress }
        guard normalized.count >= 2 else { return }

        updateMapping(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId) {
            $0.calibratedAnchors = normalized
        }
    }

    func removeCalibration(ebookStableId: String, audiobookStableId: String) {
        updateMapping(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId) {
            $0.calibratedAnchors = nil
        }
    }

    func calibrationSummary(
        ebookStableId: String,
        audiobookStableId: String
    ) -> (anchorCount: Int, averageConfidence: Double)? {
        guard
            let anchors = mappings.first(where: {
                $0.ebookStableId == ebookStableId
                    && $0.audiobookStableId == audiobookStableId
            })?.calibratedAnchors,
            !anchors.isEmpty
        else {
            return nil
        }
        return (
            anchors.count,
            anchors.reduce(0) { $0 + $1.confidence } / Double(anchors.count)
        )
    }

    func calibratedLocatorHint(
        ebookStableId: String,
        audiobookStableId: String,
        audioProgress: Double
    ) -> (quote: String, href: String?)? {
        guard
            let anchors = mappings.first(where: {
                $0.ebookStableId == ebookStableId
                    && $0.audiobookStableId == audiobookStableId
            })?.calibratedAnchors,
            let nearest = anchors.min(by: {
                abs($0.audioProgress - audioProgress) < abs($1.audioProgress - audioProgress)
            }),
            abs(nearest.audioProgress - audioProgress) <= 0.14
        else {
            return nil
        }
        return (nearest.quote, nearest.href)
    }

    func recordEbookProgress(
        book: Book,
        progression rawProgression: Double,
        exactAudioTime: TimeInterval? = nil,
        exactAudioDuration: TimeInterval? = nil,
        observedAt: Date = Date(),
        authoritative: Bool = false
    ) async {
        guard let pair = await resolvePair(for: book) else { return }
        let progression = Self.clamp(rawProgression)
        let exactAudioProgress: Double? = {
            guard book.hasEPUB3MediaOverlay,
                let exactAudioTime,
                let exactAudioDuration,
                exactAudioDuration > 0
            else {
                return nil
            }
            return Self.clamp(exactAudioTime / exactAudioDuration)
        }()

        if let exactAudioProgress {
            recordExactAnchor(
                ebookStableId: pair.ebook.stableId,
                audiobookStableId: pair.audiobook.stableId,
                ebookProgress: progression,
                audioProgress: exactAudioProgress,
                observedAt: observedAt
            )
        }

        if book.hasEPUB3MediaOverlay, exactAudioProgress == nil {
            return
        }
        guard authoritative || shouldPropagate(pairKey: pair.key, direction: "ebook", at: observedAt) else {
            return
        }

        let audioProgress: Double
        if let exactAudioProgress {
            audioProgress = exactAudioProgress
        } else {
            audioProgress = mappedAudioProgress(for: progression, pair: pair)
        }

        _ = await applyAudioProgress(
            audioProgress,
            to: pair.audiobook,
            isFinished: progression >= 0.99,
            observedAt: observedAt,
            forceRemote: authoritative
        )
    }

    func recordAudiobookProgress(
        book: Book,
        currentTime: TimeInterval,
        isFinished: Bool,
        observedAt: Date = Date(),
        authoritative: Bool = false
    ) async {
        guard book.mediaType == .audiobook,
            !book.hasEPUB3MediaOverlay,
            let pair = await resolvePair(for: book)
        else { return }
        let duration = resolvedAudioDuration(for: pair.audiobook)
        guard duration > 0 else { return }

        guard authoritative || shouldPropagate(pairKey: pair.key, direction: "audio", at: observedAt) else {
            return
        }

        let audioProgress = isFinished ? 1 : Self.clamp(currentTime / duration)
        let ebookProgress = mappedEbookProgress(for: audioProgress, pair: pair)
        _ = await applyEbookProgress(
            ebookProgress,
            to: pair.ebook,
            isFinished: isFinished,
            clearLocator: true,
            observedAt: observedAt,
            forceRemote: authoritative
        )
    }

    func reconcilePair(for book: Book) async {
        guard let pair = await resolvePair(for: book) else { return }
        guard !pair.ebook.hasEPUB3MediaOverlay else { return }

        let ebookProgress = pair.ebook.canonicalEbookProgress
        let ebookObservation: (progress: Double, observedAt: Date, isFinished: Bool)? = {
            let isFinished = pair.ebook.isFinished || ebookProgress >= 0.99
            guard ebookProgress > 0.001 || isFinished else { return nil }
            return (
                isFinished ? 1 : ebookProgress,
                pair.ebook.lastUpdate,
                isFinished
            )
        }()
        let audioObservation = freshestAudioObservation(for: pair.audiobook)

        switch (ebookObservation, audioObservation) {
        case (nil, nil):
            return
        case (let ebook?, nil):
            let audioProgress = mappedAudioProgress(for: ebook.progress, pair: pair)
            _ = await applyAudioProgress(
                audioProgress,
                to: pair.audiobook,
                isFinished: ebook.isFinished,
                observedAt: ebook.observedAt,
                forceRemote: false
            )
        case (nil, let audio?):
            let ebookProgress = mappedEbookProgress(for: audio.progress, pair: pair)
            _ = await applyEbookProgress(
                ebookProgress,
                to: pair.ebook,
                isFinished: audio.isFinished,
                clearLocator: true,
                observedAt: audio.observedAt,
                forceRemote: false
            )
        case (let ebook?, let audio?):
            if ebook.observedAt >= audio.observedAt {
                let audioProgress = mappedAudioProgress(for: ebook.progress, pair: pair)
                _ = await applyAudioProgress(
                    audioProgress,
                    to: pair.audiobook,
                    isFinished: ebook.isFinished,
                    observedAt: ebook.observedAt,
                    forceRemote: false
                )
            } else {
                let ebookProgress = mappedEbookProgress(for: audio.progress, pair: pair)
                _ = await applyEbookProgress(
                    ebookProgress,
                    to: pair.ebook,
                    isFinished: audio.isFinished,
                    clearLocator: true,
                    observedAt: audio.observedAt,
                    forceRemote: false
                )
            }
        }
    }

    func resetPair(from book: Book, observedAt: Date = Date()) async {
        await setPairFinished(from: book, finished: false, observedAt: observedAt)
    }

    func setPairFinished(
        from book: Book,
        finished: Bool,
        observedAt: Date = Date()
    ) async {
        guard let pair = await resolvePair(for: book) else { return }
        let progress: Double = finished ? 1 : 0

        _ = await applyEbookProgress(
            progress,
            to: pair.ebook,
            isFinished: finished,
            clearLocator: true,
            observedAt: observedAt,
            forceRemote: true
        )
        _ = await applyAudioProgress(
            progress,
            to: pair.audiobook,
            isFinished: finished,
            observedAt: observedAt,
            forceRemote: true
        )
    }

    private func shouldPropagate(pairKey: String, direction: String, at date: Date) -> Bool {
        let key = "\(pairKey)|\(direction)"
        if let last = lastPropagation[key],
            date.timeIntervalSince(last) < propagationInterval
        {
            return false
        }
        lastPropagation[key] = date
        return true
    }

    private func resolvePair(for input: Book) async -> Pair? {
        switch input.mediaType {
        case .ebook:
            var ebook = freshestInMemoryBook(for: input)
            if let sourceStableId = ebook.readAloudSourceStableId,
                let source = await book(stableId: sourceStableId),
                source.mediaType == .ebook
            {
                if source.linkedAudiobookStableId == nil {
                    var linkedSource = source
                    linkedSource.linkedAudiobookStableId = ebook.linkedAudiobookStableId
                    linkedSource.linkedAudiobookChapterOffset = ebook.linkedAudiobookChapterOffset
                    ebook = linkedSource
                } else {
                    ebook = source
                }
            }

            var audioStableId =
                ebook.linkedAudiobookStableId
                ?? input.linkedAudiobookStableId
            if audioStableId == nil {
                audioStableId = await self.bookRepository.linkedAudiobookStableId(
                    forEbookStableId: ebook.stableId
                )
            }
            guard let audioStableId,
                let audiobook = await book(stableId: audioStableId),
                audiobook.mediaType == .audiobook
            else { return nil }
            return Pair(ebook: ebook, audiobook: audiobook)

        case .audiobook:
            let audiobook = freshestInMemoryBook(for: input)
            var ebookStableId = await self.bookRepository.linkedEbookStableId(
                forAudiobookStableId: audiobook.stableId
            )
            if ebookStableId == nil,
                let candidate = audiobook.linkedAudiobookStableId,
                let candidateBook = await book(stableId: candidate),
                candidateBook.mediaType == .ebook
            {
                ebookStableId = candidate
            }
            guard let ebookStableId,
                let ebook = await book(stableId: ebookStableId),
                ebook.mediaType == .ebook
            else { return nil }
            return Pair(ebook: ebook, audiobook: audiobook)

        case .podcast:
            return nil
        }
    }

    private func freshestInMemoryBook(for book: Book) -> Book {
        self.libraryCache.bookInMemory(uniqueId: book.uniqueId)
            ?? self.libraryCache.bookInMemory(stableId: book.stableId)
            ?? book
    }

    private func book(stableId: String) async -> Book? {
        if let inMemory = self.libraryCache.bookInMemory(stableId: stableId) {
            return inMemory
        }
        return await self.bookRepository.book(stableId: stableId)
    }

    private func freshestAudioObservation(for book: Book) -> AudioObservation? {
        var observations: [AudioObservation] = []
        let bookDuration = book.duration ?? 0
        if bookDuration > 0, book.currentTime > 0 || book.isFinished {
            observations.append(
                AudioObservation(
                    time: book.isFinished ? bookDuration : book.currentTime,
                    duration: bookDuration,
                    observedAt: book.lastUpdate,
                    isFinished: book.isFinished
                )
            )
        }
        if let stored = BookProgressStore.shared.loadProgress(for: book),
            stored.duration > 0,
            stored.progress > 0 || book.isFinished
        {
            observations.append(
                AudioObservation(
                    time: book.isFinished ? stored.duration : stored.progress,
                    duration: stored.duration,
                    observedAt: Date(timeIntervalSince1970: stored.lastUpdated),
                    isFinished: book.isFinished || stored.progress >= stored.duration - 5
                )
            )
        }
        return observations.max { $0.observedAt < $1.observedAt }
    }

    private func resolvedAudioDuration(for book: Book) -> TimeInterval {
        let storedDuration = BookProgressStore.shared.loadProgress(for: book)?.duration ?? 0
        return max(book.duration ?? 0, storedDuration)
    }

    private func applyAudioProgress(
        _ rawProgress: Double,
        to target: Book,
        isFinished: Bool,
        observedAt: Date,
        forceRemote: Bool
    ) async -> Book? {
        let current = await book(stableId: target.stableId) ?? target
        let stored = BookProgressStore.shared.loadProgress(for: current)
        let storedUpdate = stored.map { Date(timeIntervalSince1970: $0.lastUpdated) }
        guard max(current.lastUpdate, storedUpdate ?? .distantPast) <= observedAt else {
            return nil
        }

        let duration = resolvedAudioDuration(for: current)
        guard duration > 0 else { return nil }
        let progress = isFinished ? 1 : Self.clamp(rawProgress)
        let currentTime = progress * duration
        let statusMatches =
            isFinished
            ? current.serverReadStatus == "READ"
            : current.serverReadStatus == nil
        if current.lastUpdate == observedAt,
            abs(current.currentTime - currentTime) < 0.5,
            current.isFinished == isFinished,
            statusMatches
        {
            return current
        }

        var updated = current
        updated.currentTime = currentTime
        updated.isFinished = isFinished
        updated.serverReadStatus = isFinished ? "READ" : nil
        updated.lastUpdate = observedAt

        if self.libraryCache.mutateBook(
            stableId: current.stableId,
            {
                $0.currentTime = currentTime
                $0.isFinished = isFinished
                $0.serverReadStatus = isFinished ? "READ" : nil
                $0.lastUpdate = observedAt
            }
        ) == nil {
            self.libraryCache.hot.insert(updated)
        }

        let localProgress = UserMediaProgress(
            id: UUID().uuidString,
            libraryItemId: updated.id,
            providerId: updated.providerId,
            episodeId: nil,
            currentTime: currentTime,
            progress: progress,
            isFinished: isFinished,
            duration: duration,
            lastUpdate: observedAt,
            ebookProgress: nil
        )
        UserProgressStore.shared.update(localProgress)
        BookProgressStore.shared.saveProgress(
            for: updated,
            progress: currentTime,
            duration: duration,
            at: observedAt
        )
        await self.bookRepository.updateProgress(
            uniqueId: updated.uniqueId,
            currentTime: currentTime,
            isFinished: isFinished,
            lastUpdate: observedAt
        )

        if UserProgressStore.shared.syncProgressToServer {
            await SyncCoordinator.shared.pushProgress(
                book: updated,
                forceImmediate: forceRemote,
                domain: .audiobook
            )
        }
        return updated
    }

    private func applyEbookProgress(
        _ rawProgress: Double,
        to target: Book,
        isFinished: Bool,
        clearLocator: Bool,
        observedAt: Date,
        forceRemote: Bool
    ) async -> Book? {
        let current = await book(stableId: target.stableId) ?? target
        guard current.lastUpdate <= observedAt else { return nil }

        let progress = isFinished ? 1 : Self.clamp(rawProgress)
        let statusMatches =
            isFinished
            ? current.serverReadStatus == "READ"
            : current.serverReadStatus == nil
        let locatorMatches = !clearLocator || current.epubLocator == nil
        if current.lastUpdate == observedAt,
            abs(current.canonicalEbookProgress - progress) < 0.000_5,
            current.isFinished == isFinished,
            statusMatches,
            locatorMatches
        {
            return current
        }

        var updated = current
        updated.ebookProgress = progress
        updated.isFinished = isFinished
        updated.serverReadStatus = isFinished ? "READ" : nil
        updated.lastUpdate = observedAt
        if clearLocator {
            updated.epubLocator = nil
        }

        if self.libraryCache.mutateBook(
            stableId: current.stableId,
            {
                $0.ebookProgress = progress
                $0.isFinished = isFinished
                $0.serverReadStatus = isFinished ? "READ" : nil
                $0.lastUpdate = observedAt
                if clearLocator {
                    $0.epubLocator = nil
                }
            }
        ) == nil {
            self.libraryCache.hot.insert(updated)
        }
        EbookLinkStore.shared.saveLinks()
        await self.bookRepository.updateEbookProgress(
            uniqueId: updated.uniqueId,
            ebookProgress: progress,
            epubLocator: updated.epubLocator,
            isFinished: isFinished,
            lastUpdate: observedAt
        )

        if UserProgressStore.shared.syncProgressToServer {
            await SyncCoordinator.shared.pushProgress(
                book: updated,
                forceImmediate: forceRemote,
                sourceEngine: EpubLocationBridge.sourceEngine(from: updated.epubLocator),
                domain: .ebook
            )
        }
        return updated
    }

    private func mappedAudioProgress(for ebookProgress: Double, pair: Pair) -> Double {
        interpolate(
            value: Self.clamp(ebookProgress),
            anchors: anchors(for: pair),
            source: \.ebookProgress,
            target: \.audioProgress
        )
    }

    private func mappedEbookProgress(for audioProgress: Double, pair: Pair) -> Double {
        interpolate(
            value: Self.clamp(audioProgress),
            anchors: anchors(for: pair),
            source: \.audioProgress,
            target: \.ebookProgress
        )
    }

    private func anchors(for pair: Pair) -> [Anchor] {
        let mapping = mappings.first {
            $0.ebookStableId == pair.ebook.stableId
                && $0.audiobookStableId == pair.audiobook.stableId
        }
        let interior: [Anchor]
        if let exact = mapping?.exactAnchors, !exact.isEmpty {
            interior = exact
        } else if let calibrated = mapping?.calibratedAnchors, !calibrated.isEmpty {
            interior = calibrated.map {
                Anchor(
                    ebookProgress: $0.ebookProgress,
                    audioProgress: $0.audioProgress,
                    observedAt: .distantPast
                )
            }
        } else {
            interior = chapterAnchors(
                landmarks: mapping?.chapterLandmarks
                    ?? (mapping?.chapterProgressions ?? []).map {
                        LinkedBookChapterLandmark(title: "", progression: $0)
                    },
                ebook: pair.ebook,
                audiobook: pair.audiobook
            )
        }

        return normalizedAnchors(
            [Anchor(ebookProgress: 0, audioProgress: 0, observedAt: .distantPast)]
                + interior
                + [Anchor(ebookProgress: 1, audioProgress: 1, observedAt: .distantPast)]
        )
    }

    private func chapterAnchors(
        landmarks: [LinkedBookChapterLandmark],
        ebook: Book,
        audiobook: Book
    ) -> [Anchor] {
        let duration = resolvedAudioDuration(for: audiobook)
        guard !landmarks.isEmpty,
            duration > 0,
            let chapters = audiobook.chapters?.sorted(by: { $0.start < $1.start }),
            !chapters.isEmpty
        else { return [] }

        let titleMatches = LinkedBookChapterMapper.matches(
            ebookTitles: landmarks.map(\.title),
            audiobookTitles: chapters.map(\.title)
        )
        let confidence = LinkedBookChapterMapper.mappingConfidence(
            matches: titleMatches,
            ebookCount: landmarks.count,
            audiobookCount: chapters.count
        )
        if titleMatches.count >= 2, confidence >= 0.48 {
            return titleMatches.map { match in
                Anchor(
                    ebookProgress: landmarks[match.ebookIndex].progression,
                    audioProgress: Self.clamp(chapters[match.audiobookIndex].start / duration),
                    observedAt: .distantPast
                )
            }
        }

        return landmarks.enumerated().compactMap { ebookIndex, landmark in
            let audioIndex = ebookIndex + ebook.linkedAudiobookChapterOffset
            guard chapters.indices.contains(audioIndex) else { return nil }
            return Anchor(
                ebookProgress: landmark.progression,
                audioProgress: Self.clamp(chapters[audioIndex].start / duration),
                observedAt: .distantPast
            )
        }
    }

    private func interpolate(
        value: Double,
        anchors: [Anchor],
        source: KeyPath<Anchor, Double>,
        target: KeyPath<Anchor, Double>
    ) -> Double {
        let ordered = anchors.sorted { $0[keyPath: source] < $1[keyPath: source] }
        guard let first = ordered.first, let last = ordered.last else { return value }
        if value <= first[keyPath: source] { return first[keyPath: target] }
        if value >= last[keyPath: source] { return last[keyPath: target] }

        guard let upperIndex = ordered.firstIndex(where: { $0[keyPath: source] >= value }),
            upperIndex > 0
        else { return value }
        let lower = ordered[upperIndex - 1]
        let upper = ordered[upperIndex]
        let span = upper[keyPath: source] - lower[keyPath: source]
        guard span > 0.000_001 else { return lower[keyPath: target] }
        let fraction = (value - lower[keyPath: source]) / span
        return Self.clamp(
            lower[keyPath: target]
                + fraction * (upper[keyPath: target] - lower[keyPath: target])
        )
    }

    private func recordExactAnchor(
        ebookStableId: String,
        audiobookStableId: String,
        ebookProgress: Double,
        audioProgress: Double,
        observedAt: Date
    ) {
        guard ebookProgress > 0.001, ebookProgress < 0.999,
            audioProgress > 0.001, audioProgress < 0.999
        else { return }

        updateMapping(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId) { record in
            var anchors = record.exactAnchors
            anchors.removeAll {
                abs($0.ebookProgress - ebookProgress) < 0.003
            }
            anchors.sort { $0.ebookProgress < $1.ebookProgress }

            let insertionIndex =
                anchors.firstIndex {
                    $0.ebookProgress > ebookProgress
                } ?? anchors.endIndex
            let lowerAudio =
                insertionIndex > anchors.startIndex
                ? anchors[anchors.index(before: insertionIndex)].audioProgress
                : 0
            let upperAudio =
                insertionIndex < anchors.endIndex
                ? anchors[insertionIndex].audioProgress
                : 1
            guard audioProgress >= lowerAudio - 0.005,
                audioProgress <= upperAudio + 0.005
            else { return }

            anchors.insert(
                Anchor(
                    ebookProgress: ebookProgress,
                    audioProgress: audioProgress,
                    observedAt: observedAt
                ),
                at: insertionIndex
            )
            record.exactAnchors = thinnedAnchors(anchors)
        }
    }

    private func thinnedAnchors(_ anchors: [Anchor]) -> [Anchor] {
        guard anchors.count > maximumExactAnchors else { return anchors }
        let lastIndex = anchors.count - 1
        return (0..<maximumExactAnchors).map { slot in
            let fraction = Double(slot) / Double(maximumExactAnchors - 1)
            return anchors[Int((fraction * Double(lastIndex)).rounded())]
        }
    }

    private func normalizedAnchors(_ anchors: [Anchor]) -> [Anchor] {
        let sorted =
            anchors
            .map {
                Anchor(
                    ebookProgress: Self.clamp($0.ebookProgress),
                    audioProgress: Self.clamp($0.audioProgress),
                    observedAt: $0.observedAt
                )
            }
            .sorted { $0.ebookProgress < $1.ebookProgress }

        var result: [Anchor] = []
        for anchor in sorted {
            if let last = result.last {
                if abs(last.ebookProgress - anchor.ebookProgress) < 0.000_001 {
                    if anchor.observedAt >= last.observedAt {
                        result[result.count - 1] = anchor
                    }
                    continue
                }
                guard anchor.audioProgress >= last.audioProgress else { continue }
            }
            result.append(anchor)
        }
        return result
    }

    private func updateMapping(
        ebookStableId: String,
        audiobookStableId: String,
        transform: (inout MappingRecord) -> Void
    ) {
        if let index = mappings.firstIndex(where: {
            $0.ebookStableId == ebookStableId
                && $0.audiobookStableId == audiobookStableId
        }) {
            transform(&mappings[index])
        } else {
            var mapping = MappingRecord(
                ebookStableId: ebookStableId,
                audiobookStableId: audiobookStableId,
                chapterProgressions: [],
                chapterLandmarks: nil,
                exactAnchors: [],
                calibratedAnchors: nil
            )
            transform(&mapping)
            mappings.append(mapping)
        }
        persistMappings()
    }

    private func persistMappings() {
        guard let data = try? JSONEncoder().encode(mappings) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
