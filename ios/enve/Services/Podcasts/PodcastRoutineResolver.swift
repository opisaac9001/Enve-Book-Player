import Foundation

enum PodcastRoutineFeedEpisodes: Equatable, Sendable {
    case fresh([Book])
    /// The last episode list loaded this session, used when the feed can't be fetched.
    case stale([Book])
    /// Offline with no remembered episode list: only downloads are known, so serial order can't be trusted.
    case downloadedOnly([Book])
    case failed
}

struct PodcastRoutineRuleOutcome: Identifiable, Equatable, Sendable {
    let ruleID: UUID
    let showTitle: String
    let episodes: [Book]
    let note: String?

    var id: UUID { ruleID }
}

struct PodcastRoutineRun: Equatable, Sendable {
    let routineID: UUID
    let routineName: String
    let outcomes: [PodcastRoutineRuleOutcome]
    let queuedCount: Int
    let wasOffline: Bool

    var didPlay: Bool { queuedCount > 0 }
    var explanations: [PodcastRoutineRuleOutcome] { outcomes.filter { $0.note != nil } }
}

enum PodcastRoutineSelector {
    static func resolve(
        rules: [PodcastRoutineRule],
        feeds: [String: PodcastRoutineFeedEpisodes],
        subscribedKeys: Set<String>,
        isOffline: Bool,
        isDownloaded: (Book) -> Bool
    ) -> [PodcastRoutineRuleOutcome] {
        var taken = Set<String>()
        return rules.map { rule in
            let outcome = resolve(rule, feeds: feeds, subscribedKeys: subscribedKeys, isOffline: isOffline, isDownloaded: isDownloaded, taken: taken)
            taken.formUnion(outcome.episodes.map(\.stableId))
            return outcome
        }
    }

    /// Oldest first; episodes without a date keep feed order, which lists newest first.
    static func chronological(_ episodes: [Book]) -> [Book] {
        var seen = Set<String>()
        return episodes.enumerated()
            .filter { seen.insert($0.element.stableId).inserted }
            .sorted { lhs, rhs in
                let left = lhs.element.addedAt ?? .distantPast
                let right = rhs.element.addedAt ?? .distantPast
                return left != right ? left < right : lhs.offset > rhs.offset
            }
            .map(\.element)
    }

    private static func resolve(
        _ rule: PodcastRoutineRule,
        feeds: [String: PodcastRoutineFeedEpisodes],
        subscribedKeys: Set<String>,
        isOffline: Bool,
        isDownloaded: (Book) -> Bool,
        taken: Set<String>
    ) -> PodcastRoutineRuleOutcome {
        func outcome(_ episodes: [Book] = [], note: String?) -> PodcastRoutineRuleOutcome {
            PodcastRoutineRuleOutcome(ruleID: rule.id, showTitle: rule.showTitle, episodes: episodes, note: note)
        }

        let key = PodcastFeedURL.key(rule.feedURL)
        guard subscribedKeys.contains(key) else {
            return outcome(note: "You're no longer subscribed to this show.")
        }

        let listing: [Book]
        var isStale = false
        switch feeds[key] ?? .failed {
        case .failed:
            return outcome(note: isOffline ? "No downloaded episodes are available offline." : "The feed couldn't be loaded. Try again later.")
        case .fresh(let episodes):
            listing = episodes
        case .stale(let episodes):
            listing = episodes
            isStale = !isOffline
        case .downloadedOnly(let episodes):
            if case .nextUnplayed = rule.pick {
                return outcome(note: "The episode list isn't available offline, so the next episode in order can't be confirmed. Open this show while online first.")
            }
            listing = episodes
        }

        let ordered = chronological(listing)
        func isAvailable(_ episode: Book) -> Bool { !isOffline || isDownloaded(episode) }
        let staleNote = isStale ? "Couldn't refresh this show, so the last loaded episode list was used." : nil

        switch rule.pick {
        case .newestUnplayed:
            let unplayed = ordered.reversed().filter { !$0.isCompleted }
            guard !unplayed.isEmpty else { return outcome(note: "Every episode has been played.") }
            let fresh = unplayed.filter { !taken.contains($0.stableId) }
            guard !fresh.isEmpty else { return outcome(note: "Already queued by an earlier rule.") }
            guard let pick = fresh.first(where: { isAvailable($0) }) else {
                return outcome(note: "None of the unplayed episodes are downloaded.")
            }
            return outcome([pick], note: staleNote)

        case .nextUnplayed(let count):
            let anchor = ordered.lastIndex { $0.isStarted || $0.isCompleted }
            let start = anchor.map { ordered[$0].isCompleted ? $0 + 1 : $0 } ?? 0
            let upcoming = ordered.dropFirst(start).filter { !$0.isCompleted }
            guard !upcoming.isEmpty else { return outcome(note: "You're caught up on this show.") }

            var picked: [Book] = []
            var blocked: Book?
            for episode in upcoming where picked.count < count && !taken.contains(episode.stableId) {
                guard isAvailable(episode) else {
                    blocked = episode
                    break
                }
                picked.append(episode)
            }
            if let blocked {
                let title = "“\(blocked.title)”"
                return picked.isEmpty
                    ? outcome(note: "\(title) is next but isn't downloaded, so later episodes were held back.")
                    : outcome(picked, note: "Stopped before \(title), which isn't downloaded.")
            }
            return picked.isEmpty ? outcome(note: "Already queued by an earlier rule.") : outcome(picked, note: staleNote)
        }
    }
}

@MainActor
@Observable
final class PodcastRoutineRunner {
    private(set) var runningRoutineID: UUID?
    private(set) var lastRun: PodcastRoutineRun?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let subscriptions: () -> [PodcastSubscription]
    @ObservationIgnored private let loadEpisodes: (String) async throws -> [Book]
    @ObservationIgnored private let cachedEpisodes: (String) -> [Book]?
    @ObservationIgnored private let downloadedEpisodes: () async -> [Book]
    @ObservationIgnored private let isOnline: () -> Bool
    @ObservationIgnored private let isDownloaded: (Book) -> Bool
    @ObservationIgnored private let isActive: () -> Bool
    @ObservationIgnored private let play: ([Book], String) -> Bool

    init(
        subscriptions: @escaping () -> [PodcastSubscription],
        loadEpisodes: @escaping (String) async throws -> [Book],
        cachedEpisodes: @escaping (String) -> [Book]?,
        downloadedEpisodes: @escaping () async -> [Book],
        isOnline: @escaping () -> Bool,
        isDownloaded: @escaping (Book) -> Bool,
        isActive: @escaping () -> Bool,
        play: @escaping ([Book], String) -> Bool
    ) {
        self.subscriptions = subscriptions
        self.loadEpisodes = loadEpisodes
        self.cachedEpisodes = cachedEpisodes
        self.downloadedEpisodes = downloadedEpisodes
        self.isOnline = isOnline
        self.isDownloaded = isDownloaded
        self.isActive = isActive
        self.play = play
    }

    func start(_ routine: PodcastRoutine) {
        cancel()
        generation += 1
        let token = generation
        runningRoutineID = routine.id
        lastRun = nil
        task = Task { [weak self] in
            guard let self else { return }
            let run = await self.resolveAndPlay(routine)
            guard self.generation == token else { return }
            self.runningRoutineID = nil
            self.task = nil
            if let run { self.lastRun = run }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        runningRoutineID = nil
    }

    func dismissResult() {
        lastRun = nil
    }

    // Cancellation, inactive profiles, and empty results leave the current queue untouched.
    func resolveAndPlay(_ routine: PodcastRoutine) async -> PodcastRoutineRun? {
        guard isActive(), !Task.isCancelled else { return nil }
        let online = isOnline()
        let subscribed = subscriptions()
        let feedURLByKey = Dictionary(subscribed.map { (PodcastFeedURL.key($0.feedURL), $0.feedURL) }, uniquingKeysWith: { first, _ in first })
        var ruleKeys: [String] = []
        for rule in routine.rules {
            let key = PodcastFeedURL.key(rule.feedURL)
            if feedURLByKey[key] != nil, !ruleKeys.contains(key) { ruleKeys.append(key) }
        }

        var feeds: [String: PodcastRoutineFeedEpisodes] = [:]
        var downloaded: [Book]?
        for key in ruleKeys {
            guard !Task.isCancelled, isActive(), let feedURL = feedURLByKey[key] else { return nil }
            if online {
                do {
                    feeds[key] = .fresh(try await loadEpisodes(feedURL))
                } catch {
                    feeds[key] = cachedEpisodes(feedURL).map(PodcastRoutineFeedEpisodes.stale) ?? .failed
                }
                continue
            }
            if downloaded == nil { downloaded = await downloadedEpisodes() }
            let offline = (downloaded ?? []).filter {
                $0.isPodcastEpisode && PodcastFeedURL.key($0.podcastLibraryItemId ?? "") == key && isDownloaded($0)
            }
            if let cached = cachedEpisodes(feedURL) {
                feeds[key] = .stale(cached + offline)
            } else {
                feeds[key] = offline.isEmpty ? .failed : .downloadedOnly(offline)
            }
        }
        guard !Task.isCancelled, isActive() else { return nil }

        let outcomes = PodcastRoutineSelector.resolve(
            rules: routine.rules,
            feeds: feeds,
            subscribedKeys: Set(feedURLByKey.keys),
            isOffline: !online,
            isDownloaded: isDownloaded
        )
        let queue = outcomes.flatMap(\.episodes)
        let played = !queue.isEmpty && play(queue, "podcast-routine:\(routine.id.uuidString)")
        return PodcastRoutineRun(
            routineID: routine.id,
            routineName: routine.name,
            outcomes: outcomes,
            queuedCount: played ? queue.count : 0,
            wasOffline: !online
        )
    }
}
