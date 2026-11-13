import Foundation

nonisolated struct PodcastImportCandidate: Identifiable, Equatable, Sendable {
    let key: String
    let title: String
    let feedURL: String
    let isAlreadySubscribed: Bool
    let isSubscribedInSource: Bool
    let episodes: [PodcastOPMLEpisode]

    var id: String { key }
    var playedCount: Int { episodes.count(where: \.isPlayed) }
    var inProgressCount: Int { episodes.count { !$0.isPlayed && ($0.position ?? 0) > 0 } }
    var listeningStateCount: Int { playedCount + inProgressCount }
}

nonisolated struct PodcastImportPreview: Equatable, Sendable {
    let candidates: [PodcastImportCandidate]
    let duplicateCount: Int
    let invalidCount: Int

    var newCount: Int { candidates.count { !$0.isAlreadySubscribed } }
    var alreadySubscribedCount: Int { candidates.count(where: \.isAlreadySubscribed) }
    var listeningStateCount: Int { candidates.reduce(0) { $0 + $1.listeningStateCount } }

    /// Shows the source app marks as unsubscribed start deselected; everything else starts selected.
    var defaultSelection: Set<String> {
        Set(candidates.filter { $0.isSubscribedInSource || $0.isAlreadySubscribed }.map(\.key))
    }

    init(document: PodcastOPMLDocument, existingFeedURLs: [String]) {
        let existingKeys = Set(existingFeedURLs.map(PodcastFeedURL.key))
        var order: [String] = []
        var merged: [String: PodcastOPMLFeed] = [:]
        var duplicates = 0
        for feed in document.feeds {
            let key = PodcastFeedURL.key(feed.feedURL)
            if var existing = merged[key] {
                duplicates += 1
                existing.isSubscribed = existing.isSubscribed || feed.isSubscribed
                existing.episodes += feed.episodes
                merged[key] = existing
            } else {
                order.append(key)
                merged[key] = feed
            }
        }
        candidates = order.compactMap { key in
            merged[key].map { feed in
                PodcastImportCandidate(
                    key: key,
                    title: feed.title,
                    feedURL: feed.feedURL,
                    isAlreadySubscribed: existingKeys.contains(key),
                    isSubscribedInSource: feed.isSubscribed,
                    episodes: feed.episodes.filter(\.hasListeningState)
                )
            }
        }
        duplicateCount = duplicates
        invalidCount = document.invalidFeedCount
    }
}

nonisolated enum PodcastEpisodeStateDecision: Equatable, Sendable {
    case apply(position: TimeInterval, duration: TimeInterval, updatedAt: Date)
    case keptExistingProgress
    case alreadyFinished
    case missingDuration
}

nonisolated enum PodcastEpisodeStateMerge {
    // Undated imports only fill missing records; newer progress and completion always win.
    static func decide(
        imported: PodcastOPMLEpisode,
        existing: PodcastEpisodeProgress.Stored?,
        episodeDuration: TimeInterval?,
        now: Date
    ) -> PodcastEpisodeStateDecision {
        let duration = episodeDuration.flatMap { $0 > 0 ? $0 : nil } ?? existing.flatMap { $0.duration > 0 ? $0.duration : nil }
        if let existing {
            if PodcastEpisodeProgress.isFinished(existing, duration: duration) { return .alreadyFinished }
            guard let updatedAt = imported.updatedAt, updatedAt.timeIntervalSince1970 > existing.lastUpdated else {
                return .keptExistingProgress
            }
        }
        let updatedAt = imported.updatedAt ?? now
        if imported.isPlayed {
            guard let duration else { return .missingDuration }
            return .apply(position: duration, duration: duration, updatedAt: updatedAt)
        }
        let position = imported.position ?? 0
        return .apply(position: duration.map { min(position, $0) } ?? position, duration: duration ?? 0, updatedAt: updatedAt)
    }
}

// File names and title/date can match exports whose GUIDs or tracking prefixes differ.
nonisolated struct PodcastEpisodeIndex {
    private var byGUID: [String: Book] = [:]
    private var byEnclosure: [String: Book] = [:]
    private var byFileName: [String: Book] = [:]
    private var byTitle: [String: [Book]] = [:]

    init(episodes: [Book]) {
        var fileNameCounts: [String: Int] = [:]
        for episode in episodes {
            if let guid = episode.episodeId { byGUID[guid] = byGUID[guid] ?? episode }
            if let enclosure = episode.partKey {
                let key = PodcastFeedURL.key(enclosure)
                byEnclosure[key] = byEnclosure[key] ?? episode
                if let name = Self.fileName(enclosure) {
                    fileNameCounts[name, default: 0] += 1
                    byFileName[name] = episode
                }
            }
            byTitle[Self.titleKey(episode.title), default: []].append(episode)
        }
        byFileName = byFileName.filter { fileNameCounts[$0.key] == 1 }
    }

    func match(_ imported: PodcastOPMLEpisode) -> Book? {
        if let guid = imported.guid, let episode = byGUID[guid] { return episode }
        if let enclosure = imported.enclosureURL {
            if let episode = byEnclosure[PodcastFeedURL.key(enclosure)] { return episode }
            if let name = Self.fileName(enclosure), let episode = byFileName[name] { return episode }
        }
        guard let title = imported.title else { return nil }
        let candidates = byTitle[Self.titleKey(title)] ?? []
        if let published = imported.publishedAt {
            let sameDay = candidates.filter { abs(($0.addedAt ?? .distantPast).timeIntervalSince(published)) < 36 * 3600 }
            if sameDay.count == 1 { return sameDay[0] }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func fileName(_ url: String) -> String? {
        guard let path = URLComponents(string: url)?.path else { return nil }
        let name = (path as NSString).lastPathComponent.lowercased()
        return name.count >= 8 ? name : nil
    }

    private static func titleKey(_ title: String) -> String {
        title.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).joined(separator: " ")
    }
}

struct PodcastExportExclusion: Identifiable, Equatable, Sendable {
    let title: String
    let concern: PodcastFeedURL.PrivacyConcern
    var id: String { title + concern.explanation }
}

struct PodcastExportPlan: Equatable, Sendable {
    let feeds: [PodcastOPMLExportFeed]
    let exclusions: [PodcastExportExclusion]
    let duplicateCount: Int

    var episodeStateCount: Int { feeds.reduce(0) { $0 + $1.episodes.count } }

    init(
        subscriptions: [PodcastSubscription],
        episodesByFeedKey: [String: [Book]],
        includePrivateFeeds: Bool
    ) {
        var seen = Set<String>()
        var feeds: [PodcastOPMLExportFeed] = []
        var exclusions: [PodcastExportExclusion] = []
        var duplicates = 0
        for subscription in subscriptions {
            let key = PodcastFeedURL.key(subscription.feedURL)
            guard seen.insert(key).inserted else {
                duplicates += 1
                continue
            }
            if !includePrivateFeeds, let concern = PodcastFeedURL.privacyConcern(subscription.feedURL) {
                exclusions.append(PodcastExportExclusion(title: subscription.title, concern: concern))
                continue
            }
            let episodes = (episodesByFeedKey[key] ?? []).compactMap { Self.exportedState($0, includePrivateLinks: includePrivateFeeds) }
            feeds.append(
                PodcastOPMLExportFeed(
                    title: subscription.title,
                    feedURL: PodcastFeedURL.canonical(subscription.feedURL) ?? subscription.feedURL,
                    episodes: episodes
                )
            )
        }
        self.feeds = feeds
        self.exclusions = exclusions
        duplicateCount = duplicates
    }

    private static func exportedState(_ episode: Book, includePrivateLinks: Bool) -> PodcastOPMLEpisode? {
        let played = episode.isCompleted
        guard played || episode.currentTime > 0 else { return nil }
        let enclosure = episode.partKey.flatMap { url in
            includePrivateLinks || PodcastFeedURL.privacyConcern(url) == nil ? url : nil
        }
        return PodcastOPMLEpisode(
            title: episode.title,
            guid: episode.episodeId.flatMap { includePrivateLinks || PodcastFeedURL.privacyConcern($0) == nil ? $0 : nil },
            enclosureURL: enclosure,
            publishedAt: episode.addedAt,
            updatedAt: episode.lastUpdate,
            position: played ? nil : episode.currentTime,
            isPlayed: played
        )
    }
}
