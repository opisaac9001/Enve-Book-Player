import Foundation

struct PodcastImportReport: Equatable, Sendable {
    var subscribed = 0
    var alreadySubscribed = 0
    var applied = 0
    var keptExisting = 0
    var alreadyFinished = 0
    var missingDuration = 0
    var unmatched = 0
    var unloadedFeeds: [String] = []
    var unloadedStates = 0
    var wasInterrupted = false

    var summaryLines: [String] {
        var lines = ["Added \(Self.count(subscribed, "show"))."]
        if alreadySubscribed > 0 {
            lines.append("\(Self.count(alreadySubscribed, "show")) already subscribed.")
        }
        if applied > 0 {
            lines.append("Restored listening history for \(Self.count(applied, "episode")).")
        }
        if keptExisting > 0 {
            lines.append("\(Self.count(keptExisting, "episode")) kept Enve's progress because it was the same or newer.")
        }
        if alreadyFinished > 0 {
            lines.append("\(Self.count(alreadyFinished, "episode")) already finished in Enve.")
        }
        if missingDuration > 0 {
            lines.append("\(Self.count(missingDuration, "played episode")) couldn't be marked finished because the feed doesn't list a length.")
        }
        if unmatched > 0 {
            lines.append("\(Self.count(unmatched, "episode")) no longer in the show's feed or couldn't be matched, so that history wasn't imported.")
        }
        if !unloadedFeeds.isEmpty {
            lines.append("History for \(Self.count(unloadedStates, "episode")) wasn't applied because these shows couldn't be loaded: \(unloadedFeeds.joined(separator: ", ")).")
        }
        if wasInterrupted {
            lines.append("The import stopped early. Shows already added stay; import the same file again to finish without duplicates.")
        }
        return lines
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        value == 1 ? "1 \(noun)" : "\(value) \(noun)s"
    }
}

struct PodcastExportResult: Equatable, Sendable {
    let plan: PodcastExportPlan
    let data: Data
    let feedsWithoutProgress: [String]
}

@MainActor
final class PodcastMigrationService {
    private let subscriptions: () -> [PodcastSubscription]
    private let subscribe: ([PodcastSubscription]) -> Int
    private let progress: BookProgressStore
    private let cachedEpisodes: (String) -> [Book]?
    private let loadEpisodes: (String) async throws -> [Book]
    private let isActive: () -> Bool
    private let now: () -> Date

    init(
        subscriptions: @escaping () -> [PodcastSubscription],
        subscribe: @escaping ([PodcastSubscription]) -> Int,
        progress: BookProgressStore,
        cachedEpisodes: @escaping (String) -> [Book]?,
        loadEpisodes: @escaping (String) async throws -> [Book],
        isActive: @escaping () -> Bool,
        now: @escaping () -> Date = { Date() }
    ) {
        self.subscriptions = subscriptions
        self.subscribe = subscribe
        self.progress = progress
        self.cachedEpisodes = cachedEpisodes
        self.loadEpisodes = loadEpisodes
        self.isActive = isActive
        self.now = now
    }

    func importFeeds(
        from preview: PodcastImportPreview,
        selection: Set<String>,
        onProgress: (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> PodcastImportReport {
        var report = PodcastImportReport()
        guard isActive(), !Task.isCancelled else {
            report.wasInterrupted = true
            return report
        }

        let selected = preview.candidates.filter { selection.contains($0.key) }
        let existingKeys = Set(subscriptions().map { PodcastFeedURL.key($0.feedURL) })
        let added = selected.filter { !existingKeys.contains($0.key) }
        report.alreadySubscribed = selected.count - added.count
        let date = now()
        report.subscribed = subscribe(
            added.map {
                PodcastSubscription(id: $0.feedURL, title: $0.title, feedURL: $0.feedURL, dateSubscribed: date)
            }
        )

        let withStates = selected.filter { $0.listeningStateCount > 0 }
        for (offset, candidate) in withStates.enumerated() {
            onProgress(offset, withStates.count)
            guard isActive(), !Task.isCancelled else {
                report.wasInterrupted = true
                return report
            }
            let episodes: [Book]
            if let cached = cachedEpisodes(candidate.feedURL) {
                episodes = cached
            } else {
                do {
                    episodes = try await loadEpisodes(candidate.feedURL)
                } catch {
                    report.unloadedFeeds.append(candidate.title)
                    report.unloadedStates += candidate.listeningStateCount
                    continue
                }
            }
            guard isActive(), !Task.isCancelled else {
                report.wasInterrupted = true
                return report
            }
            apply(candidate.episodes, to: episodes, report: &report)
        }
        onProgress(withStates.count, withStates.count)
        return report
    }

    func prepareExport(
        includePrivateFeeds: Bool,
        includeProgress: Bool,
        onProgress: (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> PodcastExportResult? {
        guard isActive(), !Task.isCancelled else { return nil }
        let current = subscriptions()
        let outline = PodcastExportPlan(subscriptions: current, episodesByFeedKey: [:], includePrivateFeeds: includePrivateFeeds)
        var episodesByKey: [String: [Book]] = [:]
        var withoutProgress: [String] = []
        if includeProgress {
            for (offset, feed) in outline.feeds.enumerated() {
                guard isActive(), !Task.isCancelled else { return nil }
                onProgress(offset, outline.feeds.count)
                let key = PodcastFeedURL.key(feed.feedURL)
                if let cached = cachedEpisodes(feed.feedURL) {
                    episodesByKey[key] = cached
                } else if let loaded = try? await loadEpisodes(feed.feedURL) {
                    episodesByKey[key] = loaded
                } else {
                    withoutProgress.append(feed.title)
                }
                guard isActive(), !Task.isCancelled else { return nil }
            }
            onProgress(outline.feeds.count, outline.feeds.count)
        }
        guard isActive(), !Task.isCancelled else { return nil }
        let plan = PodcastExportPlan(subscriptions: current, episodesByFeedKey: episodesByKey, includePrivateFeeds: includePrivateFeeds)
        return PodcastExportResult(
            plan: plan,
            data: PodcastOPMLWriter.data(feeds: plan.feeds, createdAt: now()),
            feedsWithoutProgress: withoutProgress
        )
    }

    private func apply(_ states: [PodcastOPMLEpisode], to episodes: [Book], report: inout PodcastImportReport) {
        let index = PodcastEpisodeIndex(episodes: episodes)
        var newestByEpisode: [String: (book: Book, state: PodcastOPMLEpisode)] = [:]
        for state in states {
            guard let book = index.match(state) else {
                report.unmatched += 1
                continue
            }
            if let current = newestByEpisode[book.stableId], !Self.supersedes(state, current.state) { continue }
            newestByEpisode[book.stableId] = (book, state)
        }

        for (book, state) in newestByEpisode.values {
            let decision = PodcastEpisodeStateMerge.decide(
                imported: state,
                existing: progress.loadProgress(for: book),
                episodeDuration: book.duration,
                now: now()
            )
            switch decision {
            case .apply(let position, let duration, let updatedAt):
                progress.saveProgress(for: book, progress: position, duration: duration, at: updatedAt)
                report.applied += 1
            case .keptExistingProgress:
                report.keptExisting += 1
            case .alreadyFinished:
                report.alreadyFinished += 1
            case .missingDuration:
                report.missingDuration += 1
            }
        }
    }

    private static func supersedes(_ candidate: PodcastOPMLEpisode, _ current: PodcastOPMLEpisode) -> Bool {
        let lhs = candidate.updatedAt ?? .distantPast
        let rhs = current.updatedAt ?? .distantPast
        return lhs != rhs ? lhs > rhs : candidate.isPlayed && !current.isPlayed
    }
}
