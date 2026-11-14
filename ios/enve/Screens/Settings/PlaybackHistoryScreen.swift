#if os(iOS)
import SwiftUI

struct PlaybackHistoryScreen: View {
    @Environment(\.hearth) private var hearth

    @State private var store: PlaybackHistoryStore
    @State private var selection: PlaybackHistoryFilter = .all
    @State private var showingClear = false
    private let bookStableId: String?
    private let bookTitle: String?

    init(profileSession: ProfileSession = .owner, bookStableId: String? = nil, bookTitle: String? = nil) {
        _store = State(initialValue: profileSession.playbackHistory)
        self.bookStableId = bookStableId
        self.bookTitle = bookTitle
    }

    var body: some View {
        SettingsScaffold(
            overline: "Playback & sync",
            title: "History",
            subtitle: bookTitle ?? "The last 7 days on this profile."
        ) {
            if scopedEntries.isEmpty {
                SourcesCard {
                    HearthEmpty(
                        glyph: "clock.arrow.circlepath",
                        title: "No history yet",
                        line: "Listening sessions, sync results, and playback problems will appear here."
                    )
                }
            } else {
                filterBar
                let groups = days(for: scopedEntries.filter(selection.includes))
                if groups.isEmpty {
                    Text("No \(selection.title.lowercased()) events yet.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(groups) { day in
                        VStack(alignment: .leading, spacing: 12) {
                            Overline(day.title)
                                .accessibilityAddTraits(.isHeader)
                            SourcesCard {
                                ForEach(day.entries) { entry in
                                    row(entry)
                                }
                            }
                        }
                    }
                }
                QuietButton(title: "Clear history", systemImage: "trash") { showingClear = true }
                    .accessibilityIdentifier("playback-history-clear")
            }
        }
        .accessibilityIdentifier("playback-history-screen")
        .confirmationDialog("Clear history?", isPresented: $showingClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { store.clear(bookStableId: bookStableId) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                bookStableId == nil
                    ? "This removes playback and sync history for this profile. Your progress isn't affected."
                    : "This removes this book's playback and sync history. Your progress isn't affected."
            )
        }
    }

    private var scopedEntries: [PlaybackHistoryEntry] {
        let recent = PlaybackHistoryStore.retained(store.entries, now: Date())
        guard let bookStableId else { return recent }
        return recent.filter { $0.bookStableId == bookStableId }
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(PlaybackHistoryFilter.allCases) { option in
                    HearthChip(title: option.title, isSelected: selection == option) { selection = option }
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History filter")
    }

    private func row(_ entry: PlaybackHistoryEntry) -> some View {
        let tint = entry.kind.isProblem ? hearth.statusWarn : hearth.ember
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.kind.systemImage)
                .font(.system(size: 14 * Hearth.visionFactor, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.opacity(0.14)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.kind.title)
                    .font(.hearthBody.weight(.medium))
                    .foregroundStyle(hearth.text)
                if bookStableId == nil {
                    Text(entry.bookTitle)
                        .font(.hearthCaption.weight(.medium))
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(2)
                }
                if let summary = entry.summary {
                    Text(summary)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(timeLine(entry))
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func timeLine(_ entry: PlaybackHistoryEntry) -> String {
        let time = entry.occurredAt.formatted(date: .omitted, time: .shortened)
        return entry.repeatCount > 1 ? "\(time) · Repeated \(entry.repeatCount) times" : time
    }

    private func days(for entries: [PlaybackHistoryEntry]) -> [PlaybackHistoryDay] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.occurredAt) }
        return grouped.keys.sorted(by: >).map { day in
            PlaybackHistoryDay(day: day, entries: grouped[day] ?? [], calendar: calendar)
        }
    }
}

private enum PlaybackHistoryFilter: String, CaseIterable, Identifiable {
    case all, playback, sync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .playback: "Playback"
        case .sync: "Sync"
        }
    }

    func includes(_ entry: PlaybackHistoryEntry) -> Bool {
        switch self {
        case .all: true
        case .playback: entry.kind.category == .playback
        case .sync: entry.kind.category == .sync
        }
    }
}

private struct PlaybackHistoryDay: Identifiable {
    let day: Date
    let entries: [PlaybackHistoryEntry]
    let title: String

    var id: Date { day }

    init(day: Date, entries: [PlaybackHistoryEntry], calendar: Calendar) {
        self.day = day
        self.entries = entries
        if calendar.isDateInToday(day) {
            title = "Today"
        } else if calendar.isDateInYesterday(day) {
            title = "Yesterday"
        } else {
            title = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }
}
#endif
