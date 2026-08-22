import SwiftUI

struct RootView: View {
    @State private var library = WatchLibraryModel.shared
    @State private var player = WatchPlayerModel.shared
    @State private var link = PhoneLink.shared

    var body: some View {
        NavigationStack {
            List {
                nowPlayingSection

                Section {
                    NavigationLink {
                        BookListView(title: "Listen Now", items: library.snapshot.continueItems)
                    } label: {
                        Label("Listen Now", systemImage: "play.circle.fill")
                    }
                    NavigationLink {
                        BookListView(title: "Podcasts", items: library.snapshot.podcastItems)
                    } label: {
                        Label("Podcasts", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    NavigationLink {
                        BookListView(title: "Recent", items: library.snapshot.recentItems)
                    } label: {
                        Label("Recent", systemImage: "clock.fill")
                    }
                    NavigationLink {
                        SearchView()
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }

                Section {
                    NavigationLink {
                        DownloadsView()
                    } label: {
                        Label("Downloads", systemImage: "arrow.down.circle.fill")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                }
            }
            .navigationTitle {
                Text("Enve")
                    .watchSerifTitle()
                    .foregroundStyle(WatchTheme.ember)
            }
        }
        .tint(WatchTheme.ember)
        .task {
            await library.refreshIfStale()
        }
    }

    @ViewBuilder
    private var nowPlayingSection: some View {
        if player.descriptor != nil {
            Section {
                NavigationLink {
                    LocalPlayerView()
                } label: {
                    NowPlayingRow(
                        stableId: player.descriptor?.stableId ?? "",
                        title: player.descriptor?.title ?? "",
                        subtitle: player.currentChapter?.title ?? player.descriptor?.author ?? "",
                        isPlaying: player.isPlaying,
                        badge: "applewatch"
                    )
                }
            }
        } else if link.nowPlaying.hasBook {
            Section {
                NavigationLink {
                    RemotePlayerView()
                } label: {
                    NowPlayingRow(
                        stableId: link.nowPlaying.stableId,
                        title: link.nowPlaying.title,
                        subtitle: link.nowPlaying.chapterTitle.isEmpty ? link.nowPlaying.author : link.nowPlaying.chapterTitle,
                        isPlaying: link.nowPlayingIsLive,
                        badge: "iphone"
                    )
                }
            }
        }
    }
}

private struct NowPlayingRow: View {
    let stableId: String
    let title: String
    let subtitle: String
    let isPlaying: Bool
    let badge: String

    var body: some View {
        HStack(spacing: 8) {
            CoverView(stableId: stableId, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(spacing: 3) {
                Image(systemName: badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: isPlaying ? "waveform" : "pause.fill")
                    .font(.caption2)
                    .foregroundStyle(WatchTheme.ember)
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            }
        }
    }
}
