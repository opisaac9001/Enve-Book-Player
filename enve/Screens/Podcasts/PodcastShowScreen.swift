import SwiftUI

struct PodcastShowScreen: View {
    let show: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss

    private let model = PodcastsModel.shared
    @State private var query = ""
    @State private var autoQueueSetting = PodcastAutoQueueSetting()
    @AppStorage("imagine.podcasts.show.newestFirst") private var newestFirst = true

    private var liveShow: AudiobookshelfProvider.PodcastShow? {
        model.show(for: show)
    }

    private var episodes: [Book] {
        liveShow?.episodes ?? []
    }

    private var filteredEpisodes: [Book] {
        var list = episodes.sorted { a, b in
            let dateA = a.addedAt ?? .distantPast
            let dateB = b.addedAt ?? .distantPast
            return newestFirst ? dateA > dateB : dateA < dateB
        }
        if !query.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(query) || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return list
    }

    private var inProgress: [Book] {
        episodes.filter { $0.isStarted && !$0.isFinished }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if model.isLoading && episodes.isEmpty {
                    loading
                } else if episodes.isEmpty {
                    emptyEpisodes
                } else {
                    tally

                    if !inProgress.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Overline("Still playing")
                            ForEach(inProgress) { episode in
                                episodeRow(episode)
                            }
                        }
                        .padding(.horizontal, 24)
                    }

                    controls

                    VStack(alignment: .leading, spacing: 10) {
                        Overline("All episodes")
                        if filteredEpisodes.isEmpty {
                            Text("No episodes match.")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                                .padding(.vertical, 24)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(filteredEpisodes) { episode in
                                    episodeRow(episode)
                                    if episode.id != filteredEpisodes.last?.id {
                                        Rectangle()
                                            .fill(hearth.hairline)
                                            .frame(height: 1)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            autoQueueSetting = autoQueueSettingFromPreferences
            await model.loadIfNeeded()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                PodcastsArt(url: show.coverURL ?? liveShow?.coverURL, size: 118)
                    .shadow(color: .black.opacity(hearth.isInk ? 0.45 : 0.18), radius: 14, y: 8)

                VStack(alignment: .leading, spacing: 5) {
                    Overline("The show")
                    Text(show.title)
                        .font(.hearthDisplay(22, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(3)
                    if let author = PodcastsFormat.displayAuthor(show.author ?? liveShow?.author), !author.isEmpty {
                        Text(author)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(2)
                    }
                    if !episodes.isEmpty {
                        Text(episodes.count == 1 ? "1 episode" : "\(episodes.count) episodes")
                            .font(.hearthUI(12))
                            .foregroundStyle(hearth.textTertiary)
                    }
                    if let genres = liveShow?.genres, !genres.isEmpty {
                        Text(genres.joined(separator: " · "))
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)

                if let feedURL = liveShow?.feedURL ?? rssFeedURL {
                    Menu {
                        Button(role: .destructive) {
                            disableAutoQueue()
                            engine.podcasts.unsubscribe(feedURL: feedURL)
                            Task { await model.reloadSubscriptions() }
                            dismiss()
                        } label: {
                            Label("Unsubscribe", systemImage: "minus.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.hearthUI(15, weight: .semibold))
                            .foregroundStyle(hearth.text)
                            .frame(width: 44, height: 44)
                            .background {
                                Circle()
                                    .fill(hearth.bgElevated)
                                    .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                            }
                    }
                    .accessibilityLabel("Show options")
                }
            }

            if let description = show.description ?? liveShow?.description, !description.isEmpty {
                Text(PodcastsFormat.cleanHTML(description))
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 24)
    }

    private var rssFeedURL: String? {
        guard let key = show.podcastLibraryItemId,
            engine.podcasts.isSubscribed(feedURL: key)
        else { return nil }
        return key
    }

    private var tally: some View {
        let played = episodes.filter(\.isFinished).count
        let playing = inProgress.count
        let unplayed = episodes.count - played - playing
        let totalHours = Int(episodes.compactMap(\.duration).reduce(0, +)) / 3600

        return HStack(spacing: 0) {
            podcastsTallyColumn("\(unplayed)", label: "Unplayed")
            podcastsTallyColumn("\(playing)", label: "Playing")
            podcastsTallyColumn("\(played)", label: "Played")
            podcastsTallyColumn("\(totalHours)h", label: "In total")
        }
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
        }
        .padding(.horizontal, 24)
    }

    private func podcastsTallyColumn(_ value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.hearthDisplay(20, weight: .semibold))
                .foregroundStyle(hearth.text)
            Overline(label, color: hearth.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.hearthUI(13, weight: .medium))
                    .foregroundStyle(hearth.textTertiary)
                TextField("Search episodes…", text: $query)
                    .font(.hearthUI(14))
                    .foregroundStyle(hearth.text)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.hearthUI(14))
                            .foregroundStyle(hearth.textTertiary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                Capsule()
                    .fill(hearth.bgElevated)
                    .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
            }

            GlyphButton(
                systemImage: newestFirst ? "arrow.down" : "arrow.up",
                glyphSize: 15,
                label: newestFirst ? "Newest first" : "Oldest first"
            ) {
                withAnimation(.snappy(duration: 0.2)) { newestFirst.toggle() }
            }

            autoQueueMenu
        }
        .padding(.horizontal, 24)
    }

    private var autoQueueMenu: some View {
        Menu {
            Section("Auto-Add New Episodes") {
                Button {
                    setAutoQueue(position: .off, limit: autoQueueSetting.limit)
                } label: {
                    if autoQueueSetting.position == .off {
                        Label("Off", systemImage: "checkmark")
                    } else {
                        Text("Off")
                    }
                }

                autoQueuePositionMenu(.next)
                autoQueuePositionMenu(.last)
            }
        } label: {
            Image(systemName: "text.badge.plus")
                .font(.hearthUI(15, weight: .semibold))
                .foregroundStyle(autoQueueSetting.position.isEnabled ? hearth.ember : hearth.text)
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(hearth.bgElevated)
                        .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                }
        }
        .accessibilityLabel("Auto-add new episodes")
        .accessibilityValue(autoQueueAccessibilityValue)
    }

    private func autoQueuePositionMenu(_ position: PodcastAutoQueuePosition) -> some View {
        Menu {
            ForEach(PodcastAutoQueueLimit.allCases) { limit in
                Button {
                    setAutoQueue(position: position, limit: limit)
                } label: {
                    if autoQueueSetting.position == position && autoQueueSetting.limit == limit {
                        Label(limit.title, systemImage: "checkmark")
                    } else {
                        Text(limit.title)
                    }
                }
            }
        } label: {
            if autoQueueSetting.position == position {
                Label(position.title, systemImage: "checkmark")
                Text(autoQueueSetting.limit.title)
            } else {
                Text(position.title)
            }
        }
    }

    private var autoQueueSettingFromPreferences: PodcastAutoQueueSetting {
        LibraryDisplayPreferencesStore.shared
            .loadPreferences()
            .podcastAutoQueueSettings[showKey] ?? PodcastAutoQueueSetting()
    }

    private var showKey: String {
        liveShow?.feedURL ?? liveShow?.id ?? show.podcastLibraryItemId ?? show.id
    }

    private var autoQueueAccessibilityValue: String {
        guard autoQueueSetting.position.isEnabled else { return "Off" }
        return "\(autoQueueSetting.position.title), \(autoQueueSetting.limit.title)"
    }

    private func setAutoQueue(
        position: PodcastAutoQueuePosition,
        limit: PodcastAutoQueueLimit
    ) {
        let wasEnabled = autoQueueSetting.position.isEnabled
        var setting = autoQueueSetting
        setting.position = position
        setting.limit = limit
        if position.isEnabled && !wasEnabled {
            setting.baselinePublishedAt = episodes.compactMap(\.addedAt).max() ?? Date()
        }

        autoQueueSetting = setting
        SettingsPrefs.mutate { preferences in
            if position.isEnabled {
                preferences.podcastAutoQueueSettings[showKey] = setting
            } else {
                preferences.podcastAutoQueueSettings.removeValue(forKey: showKey)
            }
        }
    }

    private func disableAutoQueue() {
        guard autoQueueSetting.position.isEnabled else { return }
        setAutoQueue(position: .off, limit: autoQueueSetting.limit)
    }

    private func episodeRow(_ episode: Book) -> some View {
        NavigationLink {
            PodcastsEpisodeScreen(episode: episode)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    PodcastsArt(url: episode.coverURL, size: 50, corner: 9, book: episode)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(episode.title)
                            .font(.hearthUI(14, weight: .semibold))
                            .foregroundStyle(hearth.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 5) {
                            if let duration = episode.duration, duration > 0 {
                                Text(HearthFormat.duration(duration))
                            }
                            if let date = episode.addedAt {
                                Text("· \(PodcastsFormat.relativeDate(date))")
                            }
                        }
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                        statusLine(episode)
                    }
                    Spacer(minLength: 8)
                    PodcastsDownloadControl(episode: episode)
                    GlyphButton(systemImage: "play.fill", glyphSize: 15, label: "Play \(episode.title)") {
                        engine.playback.play(episode)
                    }
                }

                if let description = episode.description, !description.isEmpty {
                    Text(PodcastsFormat.cleanHTML(description))
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if episode.isStarted && !episode.isFinished {
                    Ribbon(progress: episode.progressPercentage, tint: hearth.ember)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    @ViewBuilder
    private func statusLine(_ episode: Book) -> some View {
        HStack(spacing: 8) {
            if episode.isFinished {
                Label("Played", systemImage: "checkmark.circle.fill")
                    .font(.hearthUI(11, weight: .medium))
                    .foregroundStyle(hearth.statusOK)
            } else if episode.isStarted {
                Text("\(Int(episode.progressPercentage * 100))% played")
                    .font(.hearthUI(11, weight: .medium))
                    .foregroundStyle(hearth.ember)
            }
            if engine.downloads.isAudiobookDownloaded(downloadKey: episode.downloadKey) {
                Label("Offline", systemImage: "arrow.down.circle.fill")
                    .font(.hearthUI(11, weight: .medium))
                    .foregroundStyle(hearth.statusOK)
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(hearth.ember)
            Text("Opening the feed…")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var emptyEpisodes: some View {
        HearthEmpty(
            glyph: "waveform",
            title: "No episodes yet.",
            line: "The feed is subscribed but nothing has arrived. Pull the Podcasts page to refresh."
        )
    }
}
