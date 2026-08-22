import Combine
import SwiftUI

@MainActor
@Observable
final class PodcastsStatsModel {
    private(set) var snapshot: ListeningStatsSnapshot = .empty
    private(set) var bookLookup: [String: Book] = [:]
    private(set) var isLoading = false

    @ObservationIgnored private var liveUpdates: AnyCancellable?

    func startLiveUpdates() {
        guard liveUpdates == nil else { return }
        liveUpdates = NotificationCenter.default.publisher(for: .listeningStatsDidChange)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refresh() }
            }
    }

    func stopLiveUpdates() {
        liveUpdates?.cancel()
        liveUpdates = nil
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        snapshot = await ListeningStatsTracker.shared.currentSnapshot()
        bookLookup = await JournalStatsBookLookup.build(ids: Set(snapshot.perBook.keys))
    }

    struct Entry: Identifiable {
        let id: String
        let stat: BookListeningStat
        let book: Book

        var showName: String {
            if let podcastName = book.podcastName, !podcastName.isEmpty { return podcastName }
            return book.author ?? "Unknown show"
        }

        var hours: Double { stat.totalSeconds / 3600 }
    }

    var entries: [Entry] {
        snapshot.perBook.compactMap { key, stat in
            guard let book = bookLookup[key] ?? bookLookup[stat.bookId], book.isPodcastEpisode else { return nil }
            return Entry(id: key, stat: stat, book: book)
        }
    }

    var totalHours: Double { entries.reduce(0) { $0 + $1.hours } }
    var totalSessions: Int { entries.reduce(0) { $0 + $1.stat.sessionCount } }
    var episodesFinished: Int { entries.filter { $0.stat.isCompleted || $0.book.isFinished }.count }
    var uniqueShows: Int { Set(entries.map(\.showName)).count }

    var averageCompletion: Double {
        guard !entries.isEmpty else { return 0 }
        let values = entries.map { min(max(max($0.stat.progressPercentage, $0.book.progressPercentage), 0), 1) }
        return values.reduce(0, +) / Double(values.count)
    }

    var bingeScore: Int {
        guard uniqueShows > 0 else { return 0 }
        let sessionsPerShow = Double(totalSessions) / Double(max(uniqueShows, 1))
        return min(100, Int(sessionsPerShow * 12))
    }

    var explorerScore: Int { min(100, uniqueShows * 6) }
    var completionistScore: Int { Int(averageCompletion * 100) }

    var totalXP: Int {
        Int(totalHours * 12) + episodesFinished * 20 + uniqueShows * 8
    }

    var level: Int { max(1, totalXP / 150 + 1) }
    var xpProgress: Double { Double(totalXP % 150) / 150 }
    var xpIntoLevel: Int { totalXP % 150 }

    var rankTitle: String {
        switch level {
        case 1...3: "Rookie Listener"
        case 4...8: "Show Hopper"
        case 9...15: "Binge Explorer"
        case 16...25: "Podcast Pro"
        case 26...40: "Audio Addict"
        default: "Podcast Legend"
        }
    }

    var topShows: [(name: String, hours: Double, episodes: Int)] {
        Dictionary(grouping: entries, by: \.showName)
            .map { (name: $0.key, hours: $0.value.reduce(0) { $0 + $1.hours }, episodes: $0.value.count) }
            .sorted { $0.hours > $1.hours }
    }

    var topEpisodes: [Entry] {
        entries.sorted { $0.stat.totalSeconds > $1.stat.totalSeconds }
    }

    var achievements: [JournalBadge] {
        var list: [JournalBadge] = []
        if totalHours >= 1 { list.append(.init(id: "first_hour", title: "First hour", systemImage: "1.circle.fill")) }
        if totalHours >= 10 { list.append(.init(id: "ten_hours", title: "10 hours", systemImage: "10.circle.fill")) }
        if totalHours >= 50 { list.append(.init(id: "fifty_hours", title: "50 hours", systemImage: "star.circle.fill")) }
        if episodesFinished >= 10 { list.append(.init(id: "fin_10", title: "10 finished", systemImage: "checkmark.circle.fill")) }
        if uniqueShows >= 5 { list.append(.init(id: "shows_5", title: "Show explorer", systemImage: "globe")) }
        if bingeScore >= 80 { list.append(.init(id: "binge_80", title: "Binge master", systemImage: "bolt.fill")) }
        return list
    }
}

struct PodcastStatsScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var model = PodcastsStatsModel()
    @State private var metric: PodcastsStatsMetric = .hours
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if !loaded {
                    loading
                } else if model.entries.isEmpty {
                    emptyState
                } else {
                    levelCard
                    numbers
                    dna

                    if !model.achievements.isEmpty {
                        achievements
                    }

                    topShows
                    topEpisodes
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            loaded = true
        }
        .onAppear { model.startLiveUpdates() }
        .onDisappear { model.stopLiveUpdates() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Overline("Podcast listening")
            Text("The record")
                .font(.hearthScreenTitle)
                .foregroundStyle(hearth.text)
        }
        .padding(.horizontal, 24)
    }

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Level \(model.level)")
                    .font(.hearthDisplay(22, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Text(model.rankTitle)
                    .font(.hearthUI(13, weight: .medium))
                    .foregroundStyle(hearth.ember)
                Spacer()
                Text("\(model.totalXP) XP")
                    .font(.hearthUI(12, weight: .medium))
                    .foregroundStyle(hearth.textTertiary)
            }
            Ribbon(progress: model.xpProgress, tint: hearth.ember, height: 4)
            Text("\(model.xpIntoLevel) of 150 toward level \(model.level + 1)")
                .font(.hearthUI(11))
                .foregroundStyle(hearth.textTertiary)
        }
        .padding(18)
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

    private var numbers: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            podcastsStatNumber(String(format: "%.1f", model.totalHours), label: "Hours")
            podcastsStatNumber("\(model.totalSessions)", label: "Sessions")
            podcastsStatNumber("\(model.episodesFinished)", label: "Finished")
            podcastsStatNumber("\(model.uniqueShows)", label: "Shows")
        }
        .padding(.horizontal, 24)
    }

    private func podcastsStatNumber(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.hearthDisplay(26))
                .foregroundStyle(hearth.text)
            Overline(label, color: hearth.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dna: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Listening DNA")
            VStack(spacing: 14) {
                podcastsScoreRow("Binge", value: model.bingeScore, icon: "bolt.fill")
                podcastsScoreRow("Explorer", value: model.explorerScore, icon: "globe")
                podcastsScoreRow("Completionist", value: model.completionistScore, icon: "checkmark.seal.fill")
            }
            .padding(.horizontal, 24)
        }
    }

    private func podcastsScoreRow(_ label: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(label, systemImage: icon)
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                Spacer()
                Text("\(value)")
                    .font(.hearthDisplay(16, weight: .semibold))
                    .foregroundStyle(hearth.ember)
            }
            Ribbon(progress: Double(value) / 100, tint: hearth.ember)
        }
    }

    private var achievements: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Achievements")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.achievements) { badge in
                        HStack(spacing: 6) {
                            Image(systemName: badge.systemImage)
                                .font(.hearthUI(11))
                                .foregroundStyle(hearth.ember)
                            Text(badge.title)
                                .font(.hearthUI(12, weight: .medium))
                                .foregroundStyle(hearth.text)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background {
                            Capsule()
                                .fill(hearth.emberSoft)
                                .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var topShows: some View {
        let shows = Array(model.topShows.prefix(8))
        let maxValue = shows.map { metric == .hours ? $0.hours : Double($0.episodes) }.max() ?? 1

        return VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Top shows")
            HStack(spacing: 8) {
                ForEach(PodcastsStatsMetric.allCases, id: \.self) { choice in
                    HearthChip(title: choice.label, isSelected: metric == choice) {
                        withAnimation(.snappy(duration: 0.2)) { metric = choice }
                    }
                }
            }
            .padding(.horizontal, 24)

            VStack(spacing: 12) {
                ForEach(shows, id: \.name) { show in
                    let value = metric == .hours ? show.hours : Double(show.episodes)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(show.name)
                                .font(.hearthUI(13, weight: .medium))
                                .foregroundStyle(hearth.text)
                                .lineLimit(1)
                            Spacer()
                            Text(metric == .hours ? String(format: "%.1f h", show.hours) : "\(show.episodes) ep")
                                .font(.hearthUI(12))
                                .foregroundStyle(hearth.textTertiary)
                        }
                        Ribbon(progress: maxValue > 0 ? value / maxValue : 0, tint: hearth.ember, height: 5)
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var topEpisodes: some View {
        let episodes = Array(model.topEpisodes.prefix(8))
        return VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Top episodes")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.hearthDisplay(18, weight: .semibold))
                            .foregroundStyle(hearth.ember)
                            .frame(width: 26, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.book.title)
                                .font(.hearthUI(14, weight: .medium))
                                .foregroundStyle(hearth.text)
                                .lineLimit(2)
                            Text(entry.showName)
                                .font(.hearthUI(11))
                                .foregroundStyle(hearth.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(String(format: "%.1f h", entry.hours))
                            .font(.hearthUI(12))
                            .foregroundStyle(hearth.textSecondary)
                    }
                    .padding(.vertical, 9)
                    if entry.id != episodes.last?.id {
                        Rectangle()
                            .fill(hearth.hairline)
                            .frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(hearth.ember)
            Text("Tallying the hours…")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var emptyState: some View {
        HearthEmpty(
            glyph: "chart.bar",
            title: "The record starts with the first episode.",
            line: "Listen to a podcast and the hours, shows, and finishes will gather here."
        )
    }
}

private enum PodcastsStatsMetric: CaseIterable {
    case hours, episodes

    var label: String {
        switch self {
        case .hours: "Hours"
        case .episodes: "Episodes"
        }
    }
}
