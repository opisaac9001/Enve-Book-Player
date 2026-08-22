import SwiftUI

struct PendingMatchesScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    enum MatchesFilter: String, CaseIterable {
        case all = "All"
        case high = "High"
        case medium = "Medium"
        case low = "Low"
    }

    enum MatchesSort: String, CaseIterable {
        case confidence = "Confidence"
        case title = "Title"
        case recent = "Recent"
    }

    @State private var entries: [MatchQueueEntry] = []
    @State private var loaded = false
    @State private var selectedEntry: MatchQueueEntry?
    @State private var filter: MatchesFilter = .all
    @State private var sort: MatchesSort = .confidence
    @State private var clearConfirmShown = false

    private var pending: [MatchQueueEntry] { entries.filter { !$0.matchCandidates.isEmpty } }
    private var highCount: Int { pending.filter { confidence($0) >= 0.85 }.count }
    private var mediumCount: Int {
        pending.filter {
            let c = confidence($0); return c >= 0.70 && c < 0.85
        }.count
    }
    private var lowCount: Int { pending.filter { confidence($0) < 0.70 }.count }

    private var durationMismatchCount: Int {
        pending.filter { entry in
            guard let candidate = entry.matchCandidates.first,
                let fileDuration = entry.fileMetadata.duration,
                candidate.duration > 0
            else { return false }
            return abs(fileDuration - candidate.duration) > 60
        }.count
    }

    private var ambiguousCount: Int {
        pending.filter { entry in
            guard entry.matchCandidates.count >= 2 else { return false }
            return (entry.matchCandidates[0].confidence - entry.matchCandidates[1].confidence) < 0.05
        }.count
    }

    private var filtered: [MatchQueueEntry] {
        let subset: [MatchQueueEntry]
        switch filter {
        case .all: subset = pending
        case .high: subset = pending.filter { confidence($0) >= 0.85 }
        case .medium:
            subset = pending.filter {
                let c = confidence($0); return c >= 0.70 && c < 0.85
            }
        case .low: subset = pending.filter { confidence($0) < 0.70 }
        }
        switch sort {
        case .confidence: return subset.sorted { confidence($0) > confidence($1) }
        case .title: return subset.sorted { ($0.fileMetadata.title ?? "") < ($1.fileMetadata.title ?? "") }
        case .recent: return subset.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func confidence(_ entry: MatchQueueEntry) -> Double {
        entry.matchCandidates.first?.confidence ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if !loaded {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(hearth.ember)
                        Text("Opening the queue.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                    }
                    .padding(.horizontal, 24)
                } else if pending.isEmpty {
                    emptyState
                } else {
                    statsRow
                    filterRow

                    if filtered.isEmpty {
                        Text("Nothing in this band. Try another filter.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                            .padding(.horizontal, 24)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(filtered) { entry in
                                Button {
                                    selectedEntry = entry
                                } label: {
                                    matchesPendingRow(entry)
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            load()
        }
        .sheet(item: $selectedEntry) { entry in
            MatchesPendingEntrySheet(entry: entry) {
                load()
            }
            .enveEnvironment()
        }
        .confirmationDialog("Clear the whole queue?", isPresented: $clearConfirmShown, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) {
                engine.matches.clearPendingMatches()
                load()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all \(pending.count) pending matches. Batch matching can fill it again.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Overline("Awaiting your verdict")
                Text("Pending matches")
                    .font(.hearthScreenTitle)
                    .foregroundStyle(hearth.text)
            }
            Spacer()
            Menu {
                Section("Sort by") {
                    ForEach(MatchesSort.allCases, id: \.self) { order in
                        Button {
                            sort = order
                        } label: {
                            if sort == order {
                                Label(order.rawValue, systemImage: "checkmark")
                            } else {
                                Text(order.rawValue)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        load()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        clearConfirmShown = true
                    } label: {
                        Label("Clear all pending", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.textSecondary)
                    .frame(width: 40, height: 40)
                    .background {
                        Circle()
                            .fill(hearth.bgElevated)
                            .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                    }
            }
            .accessibilityLabel("Queue options")
        }
        .padding(.horizontal, 24)
    }

    private var statsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                matchesStat(highCount, "Ready", hearth.statusOK)
                matchesStat(mediumCount, "Review", hearth.statusWarn)
                matchesStat(lowCount, "Doubtful", hearth.statusError)
            }
            if durationMismatchCount > 0 || ambiguousCount > 0 {
                HStack(spacing: 16) {
                    if durationMismatchCount > 0 {
                        Label("\(durationMismatchCount) duration mismatch", systemImage: "clock.arrow.circlepath")
                    }
                    if ambiguousCount > 0 {
                        Label("\(ambiguousCount) ambiguous", systemImage: "square.on.square")
                    }
                }
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
            }
            if highCount > 0 && filter != .high {
                QuietButton(
                    title: highCount == 1 ? "Review the 1 confident match" : "Review \(highCount) confident matches",
                    systemImage: "bolt"
                ) {
                    filter = .high
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private func matchesStat(_ value: Int, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.hearthDisplay(28))
                .foregroundStyle(value > 0 ? tint : hearth.textTertiary)
            Overline(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MatchesFilter.allCases, id: \.self) { candidate in
                    HearthChip(title: candidate.rawValue, isSelected: filter == candidate) {
                        filter = candidate
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var emptyState: some View {
        HearthEmpty(
            glyph: "checkmark.seal",
            title: "All caught up.",
            line: "Nothing waits for review. Batch matching fills this queue when it isn't sure."
        )
    }

    private func matchesPendingRow(_ entry: MatchQueueEntry) -> some View {
        let best = entry.matchCandidates.first
        return HStack(spacing: 12) {
            ZStack {
                if let match = best, let coverUrl = match.coverUrl, !coverUrl.isEmpty {
                    MatchesRemoteCover(urlString: coverUrl, width: 44, height: 66)
                        .offset(x: 12)
                        .opacity(0.6)
                }
                MatchesRemoteCover(urlString: entry.bookCoverUrl, width: 48, height: 72)
            }
            .frame(width: 64, height: 72)

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.fileMetadata.title ?? "Unknown title")
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author = entry.fileMetadata.author {
                    Text(author)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    matchesConfidenceTag(Int((best?.confidence ?? 0) * 100), hearth: hearth)
                    Text(entry.matchCandidates.count == 1 ? "1 option" : "\(entry.matchCandidates.count) options")
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                    if let reason = matchesReason(entry) {
                        Text(reason)
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.hearthUI(12, weight: .semibold))
                .foregroundStyle(hearth.textTertiary)
        }
        .padding(12)
        .background(dedupCardBackground(hearth))
    }

    private func matchesReason(_ entry: MatchQueueEntry) -> String? {
        guard let candidate = entry.matchCandidates.first else { return "No matches found" }
        if let fileDuration = entry.fileMetadata.duration, candidate.duration > 0 {
            let diff = abs(fileDuration - candidate.duration)
            if diff > 60 {
                return "duration off by \(HearthFormat.duration(diff))"
            }
        }
        if entry.matchCandidates.count >= 2,
            entry.matchCandidates[0].confidence - entry.matchCandidates[1].confidence < 0.05
        {
            return "ambiguous"
        }
        return nil
    }

    private func load() {
        entries = engine.matches.pendingMatches()
        loaded = true
    }
}

struct MatchesPendingEntrySheet: View {
    let entry: MatchQueueEntry
    let onReviewed: () -> Void

    @Environment(EnveEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let prepared = engine.matches.preparedMetadata(for: entry)
        MatchesSearchView(
            book: engine.matches.preparedBook(for: entry),
            fileMetadata: prepared.fileMetadata,
            initialQuery: prepared.initialQuery,
            oniTunes: { layer in
                finalize(layer)
            },
            onAudible: { layer in
                finalize(layer)
            },
            onGoogleBooks: { layer in
                finalize(layer)
            },
            onOpenLibrary: { layer in
                finalize(layer)
            },
            onComicVine: { _ in },
            onEnve: { layer in
                finalize(layer)
            }
        )
    }

    private func finalize(_ layer: Any) {
        Task {
            if await engine.matches.applyPendingMatchLayer(layer, entry: entry) {
                onReviewed()
                dismiss()
            }
        }
    }
}
