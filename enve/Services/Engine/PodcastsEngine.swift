import Foundation
import Logging

@MainActor
@Observable
final class PodcastsEngine {
    private let appState: AppState
    private let subscriptionStore: PodcastSubscriptionStore

    private(set) var subscriptionRevision = 0
    var pendingBrowseGenreRawValue: String?

    init(
        appState: AppState = .shared,
        subscriptionStore: PodcastSubscriptionStore = .shared
    ) {
        self.appState = appState
        self.subscriptionStore = subscriptionStore
    }

    var subscriptions: [PodcastSubscription] {
        _ = subscriptionRevision
        return subscriptionStore.feeds
    }

    var hasSubscriptions: Bool {
        !subscriptions.isEmpty
    }

    func isSubscribed(feedURL: String) -> Bool {
        subscriptions.contains { $0.feedURL == feedURL }
    }

    func subscribe(_ subscription: PodcastSubscription) {
        let before = subscriptionStore.feeds
        subscriptionStore.subscribe(subscription)
        if before != subscriptionStore.feeds {
            subscriptionRevision += 1
        }
    }

    func unsubscribe(feedURL: String) {
        let before = subscriptionStore.feeds
        subscriptionStore.unsubscribe(feedURL: feedURL)
        if before != subscriptionStore.feeds {
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

    func fetchServerShows() async -> (shows: [AudiobookshelfProvider.PodcastShow], failed: Bool) {
        var shows: [AudiobookshelfProvider.PodcastShow] = []
        var sawFailure = false

        for connection in appState.providerConnections.connections {
            guard let provider = PluginRegistry.shared.makeLibraryProvider(for: connection) as? AudiobookshelfProvider else { continue }
            do {
                let libraries = try await provider.fetchLibraries()
                let podcastLibraries = libraries.filter {
                    $0.type.lowercased() == "podcast" || $0.type.lowercased() == "podcasts"
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
                let episodes = RSSPodcastParser.shared.convertToBooks(feed: feed, feedURL: sub.feedURL)
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
