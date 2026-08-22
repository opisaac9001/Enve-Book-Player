import SwiftUI

struct PodcastBrowseScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var selectedGenre: PodcastsGenre = {
        PodcastsGenre(rawValue: UserDefaults.standard.string(forKey: Self.genreKey) ?? "") ?? .all
    }()
    @State private var query = ""
    @State private var searchResults: [iTunesPodcastProvider.iTunesPodcast] = []
    @State private var genreResults: [iTunesPodcastProvider.iTunesPodcast] = []
    @State private var isSearching = false
    @State private var isLoadingGenre = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var preview: iTunesPodcastProvider.iTunesPodcast?
    @State private var addingFeed = false

    private static let genreKey = "imagine.podcasts.browse.genre"
    private let columns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                searchField
                genreChips

                if query.isEmpty {
                    genreSection
                } else {
                    searchSection
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(item: $preview) { podcast in
            PodcastsPreviewSheet(podcast: podcast)
                .hearthPresentationBackground()
                .presentationDragIndicator(.visible)
                .enveEnvironment()
        }
        .sheet(isPresented: $addingFeed) {
            PodcastsAddFeedSheet()
                .hearthPresentationBackground()
                .presentationDragIndicator(.visible)
                .enveEnvironment()
        }
        .task { await applyPendingGenreIfNeeded() }
        .onChange(of: engine.podcasts.pendingBrowseGenreRawValue) {
            Task { await applyPendingGenreIfNeeded() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Overline("The directory")
                Text("Browse")
                    .font(.hearthScreenTitle)
                    .foregroundStyle(hearth.text)
            }
            Spacer()
            GlyphButton(systemImage: "link.badge.plus", glyphSize: 15, label: "Add a feed by URL") {
                addingFeed = true
            }
        }
        .padding(.horizontal, 24)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.textTertiary)
            TextField("Find a voice…", text: $query)
                .font(.hearthBody)
                .foregroundStyle(hearth.text)
                .autocorrectionDisabled()
                .onSubmit { performSearch() }
            if !query.isEmpty {
                Button {
                    query = ""
                    searchResults = []
                    searchError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.hearthUI(15))
                        .foregroundStyle(hearth.textTertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            Capsule()
                .fill(hearth.bgElevated)
                .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
        }
        .padding(.horizontal, 24)
        .onChange(of: query) {
            searchTask?.cancel()
            guard !query.isEmpty else { return }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                performSearch()
            }
        }
    }

    private var genreChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(PodcastsGenre.allCases) { genre in
                    HearthChip(title: genre.rawValue, isSelected: selectedGenre == genre) {
                        Task { await select(genre) }
                    }
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var genreSection: some View {
        if isLoadingGenre && genreResults.isEmpty {
            podcastsBrowseLoading("Leafing through \(selectedGenre.rawValue)…")
        } else if genreResults.isEmpty {
            podcastsBrowseEmpty("Nothing found here. Try another shelf.")
        } else {
            resultsGrid(genreResults, heading: selectedGenre.rawValue)
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        if isSearching && searchResults.isEmpty {
            podcastsBrowseLoading("Searching…")
        } else if let searchError, searchResults.isEmpty {
            podcastsBrowseEmpty(searchError)
        } else if searchResults.isEmpty {
            podcastsBrowseEmpty("No shows answered to that name.")
        } else {
            resultsGrid(searchResults, heading: "Results")
        }
    }

    private func resultsGrid(_ podcasts: [iTunesPodcastProvider.iTunesPodcast], heading: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: heading)
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(podcasts) { podcast in
                    podcastCard(podcast)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func podcastCard(_ podcast: iTunesPodcastProvider.iTunesPodcast) -> some View {
        let subscribed = engine.podcasts.isSubscribed(feedURL: podcast.feedURL)
        return Button {
            preview = podcast
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { geo in
                    PodcastsArt(url: podcast.coverURL, size: geo.size.width)
                        .overlay(alignment: .topTrailing) {
                            if subscribed {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.hearthUI(16))
                                    .foregroundStyle(hearth.statusOK)
                                    .background(Circle().fill(hearth.bg).padding(2))
                                    .padding(7)
                            }
                        }
                }
                .aspectRatio(1, contentMode: .fit)

                Text(podcast.title)
                    .font(.hearthUI(13, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author = PodcastsFormat.displayAuthor(podcast.author) {
                    Text(author)
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }

    private func podcastsBrowseLoading(_ line: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(hearth.ember)
            Text(line)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func podcastsBrowseEmpty(_ line: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.slash")
                .font(.hearthUI(28))
                .foregroundStyle(hearth.textTertiary)
            Text(line)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }

    private func applyPendingGenreIfNeeded() async {
        if let rawValue = engine.podcasts.takePendingBrowseGenreRawValue(),
            let genre = PodcastsGenre(rawValue: rawValue)
        {
            await select(genre)
            return
        }
        if genreResults.isEmpty {
            await loadGenre(selectedGenre)
        }
    }

    private func select(_ genre: PodcastsGenre) async {
        withAnimation(.snappy(duration: 0.2)) {
            selectedGenre = genre
        }
        UserDefaults.standard.set(genre.rawValue, forKey: Self.genreKey)
        await loadGenre(genre)
    }

    private func loadGenre(_ genre: PodcastsGenre) async {
        isLoadingGenre = true
        defer { isLoadingGenre = false }
        if let results = try? await iTunesPodcastProvider.shared.search(term: genre.searchTerm, limit: 40) {
            genreResults = results
        }
    }

    private func performSearch() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        isSearching = true
        searchError = nil
        Task {
            do {
                let results = try await iTunesPodcastProvider.shared.search(term: term, limit: 30)
                searchResults = results
            } catch {
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }
}

struct PodcastsPreviewSheet: View {
    let podcast: iTunesPodcastProvider.iTunesPodcast

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var feed: RSSPodcastParser.ParsedPodcastFeed?
    @State private var isLoading = true
    @State private var loadError: String?

    private var isSubscribed: Bool {
        engine.podcasts.isSubscribed(feedURL: podcast.feedURL)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    PodcastsArt(url: podcast.coverURL, size: 96)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(podcast.title)
                            .font(.hearthDisplay(19, weight: .semibold))
                            .foregroundStyle(hearth.text)
                            .lineLimit(3)
                        if let author = PodcastsFormat.displayAuthor(podcast.author) {
                            Text(author)
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                                .lineLimit(2)
                        }
                        Text(podcast.trackCount == 1 ? "1 episode" : "\(podcast.trackCount) episodes")
                            .font(.hearthUI(12))
                            .foregroundStyle(hearth.textTertiary)
                    }
                    Spacer(minLength: 0)
                    GlyphButton(systemImage: "xmark", size: 38, glyphSize: 13, label: "Close") {
                        dismiss()
                    }
                }

                subscribeButton

                if let line = feed?.description ?? podcast.genres.first {
                    Text(PodcastsFormat.cleanHTML(line))
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(5)
                }

                Rectangle()
                    .fill(hearth.hairline)
                    .frame(height: 1)

                episodesSection
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .task { await loadFeed() }
    }

    private var subscribeButton: some View {
        Group {
            if isSubscribed {
                QuietButton(title: "Subscribed", systemImage: "checkmark") {
                    engine.podcasts.unsubscribe(feedURL: podcast.feedURL)
                    Task { await PodcastsModel.shared.reloadSubscriptions() }
                }
            } else {
                EmberButton(title: "Subscribe", systemImage: "plus") {
                    engine.podcasts.subscribe(podcast.asSubscription)
                    Task { await PodcastsModel.shared.reloadSubscriptions() }
                    PlatformHaptics.impact(.light)
                }
            }
        }
    }

    @ViewBuilder
    private var episodesSection: some View {
        if isLoading {
            HStack {
                Spacer()
                ProgressView()
                    .tint(hearth.ember)
                Spacer()
            }
            .padding(.vertical, 20)
        } else if let loadError {
            Text(loadError)
                .font(.hearthCaption)
                .foregroundStyle(hearth.statusError)
        } else if let feed {
            VStack(alignment: .leading, spacing: 14) {
                Overline(feed.episodes.count == 1 ? "1 episode" : "\(feed.episodes.count) episodes")
                ForEach(feed.episodes.prefix(20)) { episode in
                    previewEpisodeRow(episode, feed: feed)
                }
                if feed.episodes.count > 20 {
                    Text("Subscribe to see all \(feed.episodes.count) episodes.")
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.ember)
                }
            }
        }
    }

    private func previewEpisodeRow(
        _ episode: RSSPodcastParser.ParsedEpisode,
        feed: RSSPodcastParser.ParsedPodcastFeed
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    if episode.duration > 0 {
                        Text(HearthFormat.duration(episode.duration))
                    }
                    if let date = episode.publishedDate {
                        Text("· \(date.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                .font(.hearthUI(11))
                .foregroundStyle(hearth.textTertiary)
            }
            Spacer(minLength: 8)
            if episode.audioURL != nil {
                GlyphButton(systemImage: "play.fill", glyphSize: 13, label: "Play \(episode.title)") {
                    engine.playback.play(previewBook(for: episode, feed: feed))
                    dismiss()
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func previewBook(
        for episode: RSSPodcastParser.ParsedEpisode,
        feed: RSSPodcastParser.ParsedPodcastFeed
    ) -> Book {
        Book(
            id: "rss_\(episode.id)",
            title: episode.title,
            author: feed.title,
            thumb: (episode.coverURL ?? feed.coverURL)?.absoluteString,
            partKey: episode.audioURL?.absoluteString,
            duration: episode.duration > 0 ? episode.duration : nil,
            isPodcastEpisode: true,
            episodeId: episode.id,
            podcastLibraryItemId: podcast.feedURL,
            podcastName: feed.title,
            description: episode.description.map(PodcastsFormat.cleanHTML),
            addedAt: episode.publishedDate,
            currentTime: 0,
            isFinished: false,
            lastUpdate: Date(),
            libraryId: "rss_\(podcast.feedURL.hashValue)"
        )
    }

    private func loadFeed() async {
        do {
            feed = try await RSSPodcastParser.shared.parseFeed(from: podcast.feedURL)
        } catch {
            loadError = "The feed would not open: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

struct PodcastsAddFeedSheet: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var feedURL = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var parsedFeed: RSSPodcastParser.ParsedPodcastFeed?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Overline("By hand")
                    Text("Add a feed")
                        .font(.hearthDisplay(26))
                        .foregroundStyle(hearth.text)
                }

                TextField("https://example.com/feed.xml", text: $feedURL)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background {
                        Capsule()
                            .fill(hearth.bg)
                            .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
                    }

                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(hearth.ember)
                        Spacer()
                    }
                } else if parsedFeed == nil {
                    EmberButton(title: "Load feed", systemImage: "arrow.down.doc") {
                        loadFeed()
                    }
                    .disabled(feedURL.isEmpty)
                    .opacity(feedURL.isEmpty ? 0.5 : 1)
                }

                if let loadError {
                    Text(loadError)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.statusError)
                }

                if let feed = parsedFeed {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            PodcastsArt(url: feed.coverURL, size: 64)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(feed.title)
                                    .font(.hearthDisplay(17, weight: .semibold))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(2)
                                if let author = PodcastsFormat.displayAuthor(feed.author) {
                                    Text(author)
                                        .font(.hearthCaption)
                                        .foregroundStyle(hearth.textSecondary)
                                        .lineLimit(1)
                                }
                                Text(feed.episodes.count == 1 ? "1 episode" : "\(feed.episodes.count) episodes")
                                    .font(.hearthUI(12))
                                    .foregroundStyle(hearth.textTertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        EmberButton(title: "Subscribe", systemImage: "plus") {
                            subscribe(feed)
                        }
                    }
                    .padding(16)
                    .background {
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .fill(hearth.bg)
                            .overlay {
                                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                                    .strokeBorder(hearth.hairline, lineWidth: 1)
                            }
                    }
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    private func loadFeed() {
        isLoading = true
        loadError = nil
        Task {
            do {
                parsedFeed = try await RSSPodcastParser.shared.parseFeed(from: feedURL)
            } catch {
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func subscribe(_ feed: RSSPodcastParser.ParsedPodcastFeed) {
        engine.podcasts.subscribe(
            PodcastSubscription(
                id: feedURL,
                title: feed.title,
                author: feed.author,
                coverURL: feed.coverURL,
                feedURL: feedURL,
                dateSubscribed: Date()
            )
        )
        PlatformHaptics.impact(.light)
        dismiss()
    }
}
