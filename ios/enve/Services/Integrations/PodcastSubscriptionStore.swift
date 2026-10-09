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

    func subscribe(_ sub: PodcastSubscription) {
        guard !feeds.contains(where: { $0.feedURL == sub.feedURL }) else { return }
        feeds.append(sub)
        persist()
    }

    func unsubscribe(feedURL: String) {
        let before = feeds.count
        feeds.removeAll { $0.feedURL == feedURL }
        if feeds.count != before {
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(feeds) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
