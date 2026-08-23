import SwiftUI

@MainActor
@Observable
final class PodcastsModel {
    static let shared = PodcastsModel()
    private init() {}

    private(set) var serverShows: [AudiobookshelfProvider.PodcastShow] = []
    private(set) var rssShows: [AudiobookshelfProvider.PodcastShow] = []
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private var lastLoadDate: Date?

    var allShows: [AudiobookshelfProvider.PodcastShow] { serverShows + rssShows }

    var playableShows: [AudiobookshelfProvider.PodcastShow] {
        allShows.filter { !$0.episodes.isEmpty }
    }

    var hasAnySubscription: Bool {
        EnveEngine.shared.podcasts.hasSubscriptions || !serverShows.isEmpty
    }

    private var hasFreshCache: Bool {
        guard let lastLoadDate else { return false }
        return Date().timeIntervalSince(lastLoadDate) < 300 && !allShows.isEmpty
    }

    func loadIfNeeded() async {
        guard !hasFreshCache else { return }
        await load()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        async let server = podcastsFetchServerShows()
        async let rss = podcastsFetchRSSShows()
        let (serverResult, rssResult) = await (server, rss)
        serverShows = serverResult.shows
        rssShows = rssResult
        loadFailed = serverResult.failed && allShows.isEmpty && hasAnySubscription
        lastLoadDate = Date()
        isLoading = false
        EnveEngine.shared.podcastAutoQueue.reconcile(allShows)
    }

    func reloadSubscriptions() async {
        rssShows = await podcastsFetchRSSShows()
        EnveEngine.shared.podcastAutoQueue.reconcile(allShows)
    }

    func showBook(for show: AudiobookshelfProvider.PodcastShow) -> Book {
        Book(
            id: show.id,
            title: show.title,
            author: show.author,
            thumb: show.coverURL?.absoluteString,
            podcastLibraryItemId: show.feedURL ?? show.id,
            podcastName: show.title,
            mediaType: .podcast,
            description: show.description,
            genres: show.genres.isEmpty ? nil : show.genres,
            addedAt: show.addedAt
        )
    }

    func show(for book: Book) -> AudiobookshelfProvider.PodcastShow? {
        allShows.first { $0.id == book.id }
            ?? allShows.first { ($0.feedURL ?? $0.id) == book.podcastLibraryItemId }
    }

    var continueListening: [Book] {
        playableShows
            .flatMap(\.episodes)
            .filter { $0.isStarted && !$0.isFinished }
            .sorted { $0.lastUpdate > $1.lastUpdate }
    }

    var newEpisodes: [Book] {
        var seenShows = Set<String>()
        return
            playableShows
            .flatMap(\.episodes)
            .filter { !$0.isStarted && !$0.isFinished }
            .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
            .filter { seenShows.insert($0.podcastName ?? $0.title).inserted }
    }

    var totalUnplayed: Int {
        playableShows.flatMap(\.episodes).filter { !$0.isStarted && !$0.isFinished }.count
    }

    func unplayedCount(in show: AudiobookshelfProvider.PodcastShow) -> Int {
        show.episodes.filter { !$0.isStarted && !$0.isFinished }.count
    }

    #if DEBUG
    func installDebugShow() -> Book {
        let showKey = "debug://podcast-auto-queue"
        let providerID = UUID(uuidString: "40DD3857-157D-4707-8D61-63845AC9DC69")!

        func episode(_ id: String, title: String, daysAgo: Int, currentTime: TimeInterval = 0) -> Book {
            Book(
                id: id,
                title: title,
                author: "The Enve Studio",
                duration: 2_700,
                isPodcastEpisode: true,
                episodeId: id,
                podcastLibraryItemId: showKey,
                podcastName: "The Listening Room",
                dateAdded: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()),
                description: "A focused conversation about books, sound, and the rituals that make listening memorable.",
                currentTime: currentTime,
                libraryId: "debug-podcasts",
                providerId: providerID
            )
        }

        var show = AudiobookshelfProvider.PodcastShow(
            id: "debug-podcast-show",
            title: "The Listening Room",
            author: "The Enve Studio",
            description: "Quiet conversations with authors, narrators, and the people who build better ways to listen.",
            coverURL: nil,
            genres: ["Arts", "Books"],
            episodes: [
                episode("debug-episode-three", title: "The shape of a perfect chapter", daysAgo: 1),
                episode("debug-episode-two", title: "When a narrator finds the voice", daysAgo: 4),
                episode("debug-episode-one", title: "Building a listening ritual", daysAgo: 8, currentTime: 540),
            ],
            addedAt: Date()
        )
        show.feedURL = showKey
        serverShows = [show]
        rssShows = []
        lastLoadDate = Date()
        loadFailed = false
        return showBook(for: show)
    }
    #endif

    private func podcastsFetchServerShows() async -> (shows: [AudiobookshelfProvider.PodcastShow], failed: Bool) {
        await EnveEngine.shared.podcasts.fetchServerShows()
    }

    private func podcastsFetchRSSShows() async -> [AudiobookshelfProvider.PodcastShow] {
        await EnveEngine.shared.podcasts.fetchRSSShows()
    }
}

enum PodcastsGenre: String, CaseIterable, Identifiable {
    case all = "Top Charts"
    case comedy = "Comedy"
    case trueCrime = "True Crime"
    case news = "News"
    case society = "Society & Culture"
    case business = "Business"
    case health = "Health & Fitness"
    case technology = "Technology"
    case science = "Science"
    case education = "Education"
    case history = "History"
    case sports = "Sports"
    case arts = "Arts"
    case music = "Music"
    case fiction = "Fiction"
    case leisure = "Leisure"
    case government = "Government"
    case kidsFamily = "Kids & Family"
    case tvFilm = "TV & Film"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: "chart.bar.fill"
        case .comedy: "face.smiling"
        case .trueCrime: "magnifyingglass"
        case .news: "newspaper"
        case .society: "person.3.fill"
        case .business: "briefcase.fill"
        case .health: "heart.fill"
        case .technology: "desktopcomputer"
        case .science: "atom"
        case .education: "graduationcap.fill"
        case .history: "clock.arrow.circlepath"
        case .sports: "sportscourt"
        case .arts: "paintbrush.fill"
        case .music: "music.note"
        case .fiction: "book.fill"
        case .leisure: "gamecontroller.fill"
        case .government: "building.columns"
        case .kidsFamily: "figure.and.child.holdinghands"
        case .tvFilm: "tv"
        }
    }

    var searchTerm: String {
        switch self {
        case .all: "top podcast"
        case .comedy: "comedy podcast"
        case .trueCrime: "true crime podcast"
        case .news: "news podcast"
        case .society: "society culture podcast"
        case .business: "business podcast"
        case .health: "health fitness podcast"
        case .technology: "technology podcast"
        case .science: "science podcast"
        case .education: "education podcast"
        case .history: "history podcast"
        case .sports: "sports podcast"
        case .arts: "arts podcast"
        case .music: "music podcast"
        case .fiction: "fiction podcast"
        case .leisure: "leisure podcast"
        case .government: "government podcast"
        case .kidsFamily: "kids family podcast"
        case .tvFilm: "tv film podcast"
        }
    }
}
