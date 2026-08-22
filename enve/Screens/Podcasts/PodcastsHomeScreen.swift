import SwiftUI

struct PodcastsHomeScreen: View {
    var isActive: Bool = true
    var showsBackButton: Bool = true

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    private let model = PodcastsModel.shared
    @State private var heroTint: Color = Hearth.accent
    @State private var browsePushed = false
    @State private var loaded = false

    var body: some View {
        Group {
            if showsBackButton {
                content.hearthBackBar()
            } else {
                content
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $browsePushed) {
            PodcastBrowseScreen()
        }
        .refreshable { await model.load() }
        .task(id: isActive) {
            guard isActive else { return }
            await model.loadIfNeeded()
            loaded = true
            if let hero = model.continueListening.first {
                heroTint = await AmbientColorStore.shared.resolve(for: hero)
            }
        }
        .onChange(of: engine.podcasts.subscriptionRevision) {
            Task { await model.reloadSubscriptions() }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header

                if (model.isLoading || !loaded) && model.allShows.isEmpty {
                    loading
                } else if model.loadFailed {
                    failedState
                } else if !model.hasAnySubscription {
                    emptyState
                } else if model.playableShows.isEmpty {
                    quietFeeds
                } else {
                    if let upNext = model.continueListening.first {
                        upNextHero(upNext)
                            .padding(.horizontal, 24)
                    }

                    let remaining = Array(model.continueListening.dropFirst())
                    if !remaining.isEmpty {
                        stillPlaying(remaining)
                    }

                    if !model.newEpisodes.isEmpty {
                        newEpisodes
                    }

                    if model.continueListening.isEmpty && model.newEpisodes.isEmpty {
                        caughtUp
                            .padding(.horizontal, 24)
                    }

                    yourShows
                    doorways
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Overline(headerLine)
            Text("Podcasts")
                .font(.hearthScreenTitle)
                .foregroundStyle(hearth.text)
        }
        .padding(.horizontal, 24)
    }

    private var headerLine: String {
        let shows = model.newEpisodes.count
        if shows > 0 {
            return shows == 1 ? "One show has new episodes" : "\(shows) shows have new episodes"
        }
        return "The spoken word"
    }

    private func upNextHero(_ episode: Book) -> some View {
        NavigationLink {
            PodcastsEpisodeScreen(episode: episode)
        } label: {
            HStack(alignment: .top, spacing: 18) {
                PodcastsArt(url: episode.coverURL, size: 124, book: episode)
                    .shadow(color: heroTint.opacity(0.25), radius: 24, y: 8)

                VStack(alignment: .leading, spacing: 7) {
                    Overline("Up next", color: hearth.ember)
                    Text(episode.title)
                        .font(.hearthDisplay(20, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if let show = episode.podcastName {
                        Text(show)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                    if episode.progressPercentage > 0 {
                        Ribbon(progress: episode.progressPercentage, tint: heroTint)
                            .padding(.top, 2)
                        if let duration = episode.duration, duration > 0 {
                            Text(HearthFormat.remaining(duration - episode.currentTime))
                                .font(.hearthUI(12))
                                .foregroundStyle(hearth.textTertiary)
                        }
                    }
                    EmberButton(title: "Continue", systemImage: "play.fill", tint: heroTint) {
                        engine.playback.play(episode)
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .fill(hearth.bgElevated)
                    EmberGlow(tint: heroTint, isBreathing: false, intensity: 0.35)
                        .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous))
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }

    private func stillPlaying(_ episodes: [Book]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Still playing")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(episodes.prefix(10)) { episode in
                        NavigationLink {
                            PodcastsEpisodeScreen(episode: episode)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                PodcastsArt(url: episode.coverURL, size: 108, book: episode)
                                Text(episode.title)
                                    .font(.hearthUI(12, weight: .medium))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Ribbon(progress: episode.progressPercentage, tint: hearth.ember)
                            }
                            .frame(width: 108)
                        }
                        .buttonStyle(PressableStyle())
                        .contextMenu {
                            Button("Play", systemImage: "play") {
                                engine.playback.play(episode)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var newEpisodes: some View {
        let episodes = Array(model.newEpisodes.prefix(8))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Overline("New episodes")
                Spacer()
                Text(model.totalUnplayed == 1 ? "1 episode" : "\(model.totalUnplayed) episodes")
                    .font(.hearthUI(12))
                    .foregroundStyle(hearth.textTertiary)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 0) {
                ForEach(episodes) { episode in
                    NavigationLink {
                        PodcastsEpisodeScreen(episode: episode)
                    } label: {
                        newEpisodeRow(episode)
                    }
                    .buttonStyle(PressableStyle())
                    if episode.id != episodes.last?.id {
                        Rectangle()
                            .fill(hearth.hairline)
                            .frame(height: 1)
                            .padding(.leading, 74)
                    }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous))
            .padding(.horizontal, 24)
        }
    }

    private func newEpisodeRow(_ episode: Book) -> some View {
        HStack(spacing: 12) {
            PodcastsArt(url: episode.coverURL, size: 46, corner: 9, book: episode)
            VStack(alignment: .leading, spacing: 3) {
                if let show = episode.podcastName {
                    Text(show)
                        .font(.hearthUI(11, weight: .semibold))
                        .foregroundStyle(hearth.ember)
                        .lineLimit(1)
                }
                Text(episode.title)
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    if let date = episode.addedAt {
                        Text(PodcastsFormat.relativeDate(date))
                    }
                    if let duration = episode.duration, duration > 0 {
                        Text("· \(HearthFormat.duration(duration))")
                    }
                }
                .font(.hearthUI(11))
                .foregroundStyle(hearth.textTertiary)
            }
            Spacer(minLength: 8)
            GlyphButton(systemImage: "play.fill", glyphSize: 15, label: "Play \(episode.title)") {
                engine.playback.play(episode)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var caughtUp: some View {
        HearthEmpty(
            glyph: "checkmark.seal",
            title: "All caught up.",
            line: "Every recent episode has been heard. The feeds are quiet for now."
        )
    }

    private var yourShows: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Your shows")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(model.playableShows, id: \.id) { show in
                        NavigationLink {
                            PodcastShowScreen(show: model.showBook(for: show))
                        } label: {
                            showTile(show)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func showTile(_ show: AudiobookshelfProvider.PodcastShow) -> some View {
        let unplayed = model.unplayedCount(in: show)
        return VStack(spacing: 7) {
            PodcastsArt(url: show.coverURL, size: 84)
                .overlay(alignment: .topTrailing) {
                    if unplayed > 0 {
                        Text("\(min(unplayed, 99))")
                            .font(.hearthUI(10, weight: .bold))
                            .foregroundStyle(hearth.onEmber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(hearth.ember))
                            .offset(x: 6, y: -6)
                    }
                }
            Text(show.title)
                .font(.hearthUI(11, weight: .medium))
                .foregroundStyle(hearth.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 104)
        }
    }

    private var doorways: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Further")
            VStack(spacing: 1) {
                HearthDoorway(glyph: "sparkle.magnifyingglass", title: "Find new shows", line: "Search the directory, browse by genre") {
                    PodcastBrowseScreen()
                }
                HearthDoorway(glyph: "chart.bar", title: "The record", line: "Hours, shows, and what you finished") {
                    PodcastStatsScreen()
                }
            }
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous))
            .padding(.horizontal, 24)
        }
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(hearth.ember)
            Text("Gathering your shows…")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var failedState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The feeds did not answer.")
                .font(.hearthDisplay(20, weight: .semibold))
                .foregroundStyle(hearth.text)
            Text("Check the connection and try again.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
            QuietButton(title: "Try again", systemImage: "arrow.clockwise") {
                Task { await model.load() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
    }

    private var quietFeeds: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nothing on the air yet.")
                .font(.hearthDisplay(20, weight: .semibold))
                .foregroundStyle(hearth.text)
            Text("Your shows are subscribed but no episodes arrived. Pull to refresh, or find something new.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                QuietButton(title: "Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                QuietButton(title: "Browse", systemImage: "sparkle.magnifyingglass") {
                    browsePushed = true
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                EmberGlow(tint: Hearth.accent, isBreathing: true, intensity: 0.8)
                    .frame(height: 170)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.hearthUI(42))
                    .foregroundStyle(Hearth.accent)
            }
            .frame(maxWidth: .infinity)

            Text("Tune the quiet.")
                .font(.hearthDisplay(26))
                .foregroundStyle(hearth.text)
            Text("Subscribe to the voices you want in the room and their new episodes will gather here.")
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            EmberButton(title: "Browse podcasts", systemImage: "sparkle.magnifyingglass") {
                browsePushed = true
            }

            VStack(alignment: .leading, spacing: 12) {
                Overline("Or start with a genre")
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(podcastsEmptyStateGenres) { genre in
                            HearthChip(title: genre.rawValue, isSelected: false) {
                                engine.podcasts.queueBrowseGenre(rawValue: genre.rawValue)
                                browsePushed = true
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    private var podcastsEmptyStateGenres: [PodcastsGenre] {
        [.trueCrime, .technology, .science, .business, .society, .health, .education, .arts, .sports, .comedy]
    }
}
