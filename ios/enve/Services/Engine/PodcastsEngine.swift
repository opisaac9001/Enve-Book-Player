import Foundation
import Logging

@MainActor
@Observable
final class PodcastsEngine {
    private let appState: AppState
    private let subscriptionStore: PodcastSubscriptionStore
    let routines: PodcastRoutineStore

    private(set) var subscriptionRevision = 0
    var pendingBrowseGenreRawValue: String?

    @ObservationIgnored private weak var profileSession: ProfileSession?
    private let hasProfileSession: Bool
    @ObservationIgnored private let suppliedEpisodeProgress: BookProgressStore?
    @ObservationIgnored private var episodeCache: [String: [Book]] = [:]

    @ObservationIgnored private(set) lazy var migration = PodcastMigrationService(
        subscriptions: { [weak self] in self?.subscriptions ?? [] },
        subscribe: { [weak self] in self?.subscribe(contentsOf: $0) ?? 0 },
        progress: episodeProgress,
        cachedEpisodes: { [weak self] in self?.cachedEpisodes(feedURL: $0) },
        loadEpisodes: { [weak self] url in
            guard let self else { throw CancellationError() }
            return try await self.loadEpisodes(feedURL: url)
        },
        isActive: { [weak self] in self?.isProfileActive == true }
    )

    @ObservationIgnored private(set) lazy var routineRunner = PodcastRoutineRunner(
        subscriptions: { [weak self] in self?.subscriptions ?? [] },
        loadEpisodes: { [weak self] url in
            guard let self else { throw CancellationError() }
            return try await self.loadEpisodes(feedURL: url)
        },
        cachedEpisodes: { [weak self] in self?.cachedEpisodes(feedURL: $0) },
        downloadedEpisodes: { @MainActor [weak self] in
            guard let self, self.isProfileActive else { return [] }
            let books = await self.enveEngine.downloads.downloadedStorageItems().compactMap(\.book)
            guard self.isProfileActive else { return [] }
            return self.hydrated(books)
        },
        isOnline: { [weak self] in self?.enveEngine.downloads.isNetworkAvailable == true },
        isDownloaded: { [weak self] in self?.enveEngine.downloads.isAudiobookDownloaded(downloadKey: $0.downloadKey) == true },
        isActive: { [weak self] in self?.isProfileActive == true },
        play: { [weak self] books, group in
            guard let self, self.isProfileActive else { return false }
            return self.enveEngine.playback.playAll(books, groupKey: group)
        }
    )

    init(profileSession: ProfileSession? = nil,
        appState: AppState = .shared,
        subscriptionStore: PodcastSubscriptionStore = .shared,
        routineStore: PodcastRoutineStore? = nil,
        episodeProgress: BookProgressStore? = nil
    ) {
        self.profileSession = profileSession
        hasProfileSession = profileSession != nil
        self.appState = appState
        self.subscriptionStore = subscriptionStore
        self.routines = routineStore ?? PodcastRoutineStore(defaults: profileSession?.defaults ?? .standard)
        self.suppliedEpisodeProgress = episodeProgress
    }

    var subscriptions: [PodcastSubscription] {
        _ = subscriptionRevision
        return subscriptionStore.feeds
    }

    var hasSubscriptions: Bool {
        !subscriptions.isEmpty
    }

    var includesAudiobookshelfPodcasts: Bool {
        (profileSession?.preferences ?? LibraryDisplayPreferencesStore.shared).loadPreferences().includeAudiobookshelfPodcasts
    }

    /// Work started for one profile must not write into another after a switch.
    var isProfileActive: Bool {
        guard let profileSession else { return !hasProfileSession }
        return !profileSession.isRetired && ProfileSwitchCoordinator.shared.activeSession === profileSession
    }

    private var episodeProgress: BookProgressStore {
        suppliedEpisodeProgress ?? profileSession?.bookProgress ?? .shared
    }

    private var enveEngine: EnveEngine {
        profileSession?.engine ?? .shared
    }

    func isSubscribed(feedURL: String) -> Bool {
        _ = subscriptionRevision
        return subscriptionStore.contains(feedURL: feedURL)
    }

    func subscribe(_ subscription: PodcastSubscription) {
        subscribe(contentsOf: [subscription])
    }

    @discardableResult
    func subscribe(contentsOf newSubscriptions: [PodcastSubscription]) -> Int {
        let added = subscriptionStore.subscribe(contentsOf: newSubscriptions)
        if added > 0 {
            subscriptionRevision += 1
        }
        return added
    }

    func unsubscribe(feedURL: String) {
        let before = subscriptionStore.feeds
        subscriptionStore.unsubscribe(feedURL: feedURL)
        if before != subscriptionStore.feeds {
            episodeCache[PodcastFeedURL.key(feedURL)] = nil
            subscriptionRevision += 1
        }
    }

    func queueBrowseGenre(rawValue: String) {
        pendingBrowseGenreRawValue = rawValue
    }

    func takePendingBrowseGenreRawValue() -> String? {
        let value = pendingBrowseGenreRawValue
        pendingBrowseGenreRawValue = nil
        return value
    }

    func hydrated(_ episodes: [Book]) -> [Book] {
        episodes.map { PodcastEpisodeProgress.hydrate($0, stored: episodeProgress.loadProgress(for: $0)) }
    }

    func cachedEpisodes(feedURL: String) -> [Book]? {
        episodeCache[PodcastFeedURL.key(feedURL)].map(hydrated)
    }

    func loadEpisodes(feedURL: String) async throws -> [Book] {
        guard isProfileActive, !Task.isCancelled else { throw CancellationError() }
        let feed = try await RSSPodcastParser.shared.parseFeed(from: feedURL)
        guard isProfileActive, !Task.isCancelled else { throw CancellationError() }
        let episodes = hydrated(RSSPodcastParser.shared.convertToBooks(feed: feed, feedURL: feedURL))
        episodeCache[PodcastFeedURL.key(feedURL)] = episodes
        return episodes
    }

    func fetchServerShows() async -> (shows: [AudiobookshelfProvider.PodcastShow], failed: Bool) {
        guard includesAudiobookshelfPodcasts else {
            return ([], false)
        }

        var shows: [AudiobookshelfProvider.PodcastShow] = []
        var sawFailure = false

        for connection in appState.providerConnections.connections {
            guard let provider = (profileSession?.registry ?? PluginRegistry.shared).makeLibraryProvider(for: connection) as? AudiobookshelfProvider else { continue }
            do {
                let libraries = try await provider.fetchLibraries()
                let selectedLibraryIds = connection.selectedLibraryIds ?? []
                let podcastLibraries = libraries.filter {
                    let type = $0.type.lowercased()
                    return (type == "podcast" || type == "podcasts")
                        && (selectedLibraryIds.isEmpty || selectedLibraryIds.contains($0.id))
                }
                for library in podcastLibraries {
                    do {
                        shows.append(contentsOf: try await provider.fetchPodcasts(libraryId: library.id))
                    } catch {
                        sawFailure = true
                        AppLogger.general.error("Failed to fetch podcasts from library \(library.name): \(error)")
                    }
                }
            } catch {
                sawFailure = true
                AppLogger.general.error("Failed to fetch libraries from \(connection.name): \(error)")
            }
        }

        return (shows, sawFailure)
    }

    func fetchRSSShows() async -> [AudiobookshelfProvider.PodcastShow] {
        var shows: [AudiobookshelfProvider.PodcastShow] = []

        for sub in subscriptions {
            do {
                let feed = try await RSSPodcastParser.shared.parseFeed(from: sub.feedURL)
                let episodes = hydrated(RSSPodcastParser.shared.convertToBooks(feed: feed, feedURL: sub.feedURL))
                episodeCache[PodcastFeedURL.key(sub.feedURL)] = episodes
                var show = AudiobookshelfProvider.PodcastShow(
                    id: "rss_\(sub.feedURL.hashValue)",
                    title: feed.title.isEmpty ? sub.title : feed.title,
                    author: feed.author ?? sub.author,
                    description: feed.description,
                    coverURL: feed.coverURL ?? sub.coverURL,
                    genres: [],
                    episodes: episodes,
                    addedAt: sub.dateSubscribed
                )
                show.feedURL = sub.feedURL
                shows.append(show)
            } catch {
                AppLogger.general.error(
                    "Failed to parse RSS feedId=\(DiagnosticLogSanitizer.identifier(for: sub.feedURL)): \(error)"
                )
                var show = AudiobookshelfProvider.PodcastShow(
                    id: "rss_\(sub.feedURL.hashValue)",
                    title: sub.title,
                    author: sub.author,
                    description: nil,
                    coverURL: sub.coverURL,
                    genres: [],
                    episodes: [],
                    addedAt: sub.dateSubscribed
                )
                show.feedURL = sub.feedURL
                shows.append(show)
            }
        }

        return shows
    }
}
