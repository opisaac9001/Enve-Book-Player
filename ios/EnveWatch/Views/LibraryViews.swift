import SwiftUI

struct BookListView: View {
    let title: String
    let items: [WatchBookSummary]

    @State private var library = WatchLibraryModel.shared

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(title, systemImage: "books.vertical")
                } description: {
                    Text(library.isRefreshing ? "Loading from iPhone…" : "Nothing here yet. Pull from your iPhone library by refreshing.")
                }
            } else {
                List(items) { item in
                    NavigationLink {
                        BookActionsView(summary: item)
                    } label: {
                        BookRow(summary: item)
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await library.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(library.isRefreshing)
            }
        }
    }
}

struct BookRow: View {
    let summary: WatchBookSummary

    var body: some View {
        HStack(spacing: 8) {
            CoverView(stableId: summary.stableId, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2)
                Text(summary.isPodcastEpisode ? (summary.podcastName ?? summary.author) : summary.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if summary.progressFraction > 0.001 && !summary.isFinished {
                    ProgressView(value: summary.progressFraction)
                        .tint(WatchTheme.ember)
                }
            }
            if summary.isFinished {
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(WatchTheme.ember)
            }
        }
    }
}

struct BookActionsView: View {
    let summary: WatchBookSummary

    @State private var player = WatchPlayerModel.shared
    @State private var downloads = WatchDownloadManager.shared
    @State private var localStore = WatchLocalStore.shared
    @State private var link = PhoneLink.shared
    @Environment(\.dismiss) private var dismiss

    private var localBook: WatchLocalBook? {
        localStore.book(stableId: summary.stableId)
    }

    private var downloadStatus: WatchDownloadStatus? {
        downloads.active[summary.stableId]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                CoverView(stableId: summary.stableId, size: 68)
                Text(summary.title)
                    .font(.footnote.weight(.semibold))
                    .watchSerifTitle()
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text(summary.isPodcastEpisode ? (summary.podcastName ?? summary.author) : summary.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if summary.duration > 0 {
                    Text(WatchTheme.remainingString(position: summary.position, duration: summary.duration))
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.ember)
                }

                Button {
                    let target = summary.stableId
                    Task {
                        await player.play(stableId: target)
                    }
                    dismiss()
                } label: {
                    Label(localBook?.isComplete == true ? "Play on Watch" : "Stream on Watch", systemImage: "applewatch")
                }
                .buttonStyle(.borderedProminent)
                .tint(WatchTheme.ember)

                Button {
                    link.sendCommand(WatchCommandPayload(action: .play, value: summary.stableId))
                    dismiss()
                } label: {
                    Label("Play on iPhone", systemImage: "iphone")
                }

                downloadButton

                if let error = player.playbackError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Book")
    }

    @ViewBuilder
    private var downloadButton: some View {
        if let localBook, localBook.isComplete {
            Button(role: .destructive) {
                localStore.delete(stableId: summary.stableId)
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else if let status = downloadStatus {
            switch status {
            case .preparing:
                Button {
                    downloads.cancel(stableId: summary.stableId)
                } label: {
                    Label("Preparing…", systemImage: "xmark.circle")
                }
            case .downloading(let fraction):
                Button {
                    downloads.cancel(stableId: summary.stableId)
                } label: {
                    VStack(spacing: 3) {
                        Label("Cancel \(Int(fraction * 100))%", systemImage: "xmark.circle")
                        ProgressView(value: fraction)
                            .tint(WatchTheme.ember)
                    }
                }
            case .failed(let message):
                VStack(spacing: 4) {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                    Button {
                        downloads.dismissFailure(stableId: summary.stableId)
                        Task { await downloads.start(stableId: summary.stableId) }
                    } label: {
                        Label("Retry Download", systemImage: "arrow.clockwise")
                    }
                }
            }
        } else {
            Button {
                Task { await downloads.start(stableId: summary.stableId) }
            } label: {
                Label("Download to Watch", systemImage: "arrow.down.circle")
            }
        }
    }
}

struct SearchView: View {
    @State private var query = ""
    @State private var results: [WatchBookSummary] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            TextField("Search library", text: $query)
                .onSubmit { runSearch() }

            if isSearching {
                ProgressView()
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if results.isEmpty && !query.isEmpty {
                Text("No matches.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(results) { item in
                NavigationLink {
                    BookActionsView(summary: item)
                } label: {
                    BookRow(summary: item)
                }
            }
        }
        .navigationTitle("Search")
    }

    private func runSearch() {
        let text = query
        isSearching = true
        errorMessage = nil
        Task {
            defer { isSearching = false }
            do {
                results = try await WatchLibraryModel.shared.search(text)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
