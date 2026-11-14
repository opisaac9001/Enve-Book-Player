import Foundation

struct PodcastSubscription: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var author: String?
    var coverURL: URL?
    var feedURL: String
    var dateSubscribed: Date
}

@MainActor
@Observable
final class PodcastSubscriptionStore {
    static let shared = PodcastSubscriptionStore()

    @ObservationIgnored private static let storageKey = "podcast_subscriptions"

    private(set) var feeds: [PodcastSubscription]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([PodcastSubscription].self, from: data)
        {
            self.feeds = decoded
        } else {
            self.feeds = []
        }
    }

    func contains(feedURL: String) -> Bool {
        let key = PodcastFeedURL.key(feedURL)
        return feeds.contains { PodcastFeedURL.key($0.feedURL) == key }
    }

    func subscribe(_ sub: PodcastSubscription) {
        subscribe(contentsOf: [sub])
    }

    /// Persists once for the whole batch; returns how many feeds were new.
    @discardableResult
    func subscribe(contentsOf subscriptions: [PodcastSubscription]) -> Int {
        var keys = Set(feeds.map { PodcastFeedURL.key($0.feedURL) })
        let added = subscriptions.filter { keys.insert(PodcastFeedURL.key($0.feedURL)).inserted }
        guard !added.isEmpty else { return 0 }
        feeds.append(contentsOf: added)
        persist()
        return added.count
    }

    func unsubscribe(feedURL: String) {
        let key = PodcastFeedURL.key(feedURL)
        let before = feeds.count
        feeds.removeAll { PodcastFeedURL.key($0.feedURL) == key }
        if feeds.count != before {
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(feeds) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
