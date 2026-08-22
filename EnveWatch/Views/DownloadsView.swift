import SwiftUI

struct DownloadsView: View {
    @State private var localStore = WatchLocalStore.shared
    @State private var downloads = WatchDownloadManager.shared
    @State private var player = WatchPlayerModel.shared

    private var activeIds: [String] {
        downloads.active.keys.sorted()
    }

    private var completedBooks: [WatchLocalBook] {
        localStore.books.filter { $0.isComplete }.sorted { $0.savedAt > $1.savedAt }
    }

    var body: some View {
        List {
            if !activeIds.isEmpty {
                Section("In Progress") {
                    ForEach(activeIds, id: \.self) { stableId in
                        activeRow(stableId: stableId)
                    }
                }
            }

            if completedBooks.isEmpty && activeIds.isEmpty {
                ContentUnavailableView {
                    Label("No Downloads", systemImage: "arrow.down.circle")
                } description: {
                    Text("Download books from the library to listen without your iPhone.")
                }
            } else if !completedBooks.isEmpty {
                Section("On Watch") {
                    ForEach(completedBooks) { book in
                        Button {
                            let target = book.descriptor.stableId
                            Task { await player.play(stableId: target) }
                        } label: {
                            downloadedRow(book)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                localStore.delete(stableId: book.descriptor.stableId)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                Section {
                    Text("Total: \(WatchTheme.sizeString(localStore.totalSizeBytes()))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Downloads")
    }

    @ViewBuilder
    private func activeRow(stableId: String) -> some View {
        let title =
            localStore.book(stableId: stableId)?.descriptor.title
            ?? WatchLibraryModel.shared.summary(for: stableId)?.title
            ?? "Downloading"
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .lineLimit(2)
            switch downloads.active[stableId] {
            case .preparing:
                Text("Preparing…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .tint(WatchTheme.ember)
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            case nil:
                EmptyView()
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                downloads.cancel(stableId: stableId)
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            if case .failed = downloads.active[stableId] {
                Button {
                    downloads.dismissFailure(stableId: stableId)
                    Task { await downloads.start(stableId: stableId) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func downloadedRow(_ book: WatchLocalBook) -> some View {
        HStack(spacing: 8) {
            CoverView(stableId: book.descriptor.stableId, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.descriptor.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(2)
                Text(WatchTheme.sizeString(localStore.sizeBytes(stableId: book.descriptor.stableId)))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if player.isCurrent(book.descriptor.stableId) {
                Spacer(minLength: 0)
                Image(systemName: "waveform")
                    .font(.caption2)
                    .foregroundStyle(WatchTheme.ember)
            }
        }
    }
}

struct SettingsView: View {
    @State private var library = WatchLibraryModel.shared
    @State private var link = PhoneLink.shared
    @State private var localStore = WatchLocalStore.shared

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("iPhone") {
                    Text(link.isReachable ? "Reachable" : "Not reachable")
                        .foregroundStyle(link.isReachable ? WatchTheme.ember : .secondary)
                }
                Button {
                    Task { await library.refresh() }
                } label: {
                    if library.isRefreshing {
                        ProgressView()
                    } else {
                        Label("Refresh Library", systemImage: "arrow.clockwise")
                    }
                }
                if let error = library.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Section("Storage") {
                LabeledContent("Downloads") {
                    Text(WatchTheme.sizeString(localStore.totalSizeBytes()))
                }
                if !localStore.books.isEmpty {
                    Button(role: .destructive) {
                        for stableId in WatchDownloadManager.shared.active.keys {
                            WatchDownloadManager.shared.cancel(stableId: stableId)
                        }
                        for book in localStore.books.filter(\.isComplete) {
                            localStore.delete(stableId: book.descriptor.stableId)
                        }
                    } label: {
                        Label("Remove All Downloads", systemImage: "trash")
                    }
                }
            }

            Section {
                Text("Enve Book Player")
                    .watchSerifTitle()
                    .foregroundStyle(WatchTheme.ember)
                Text("Library, playback and sync are provided by the Enve app on your iPhone. Downloads play standalone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
        }
        .navigationTitle("Settings")
    }
}
