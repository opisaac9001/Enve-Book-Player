import SwiftUI

struct RecentlyDeletedScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    @State private var entries: [RecentlyDeletedBookEntry] = []
    @State private var isRestoring = false
    @State private var showingRestoreAll = false

    var body: some View {
        SettingsScaffold(
            overline: "Library & content",
            title: "Recently deleted",
            subtitle: entries.isEmpty ? nil : "\(entries.count) waiting to come back."
        ) {
            if entries.isEmpty {
                SourcesCard {
                    Text("Nothing here. Books you remove rest here until you restore them.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SourcesCard {
                    HStack {
                        Overline("Deleted")
                        Spacer()
                        Button("Restore all") { showingRestoreAll = true }
                            .font(.hearthCaption.weight(.medium))
                            .foregroundStyle(hearth.ember)
                            .disabled(isRestoring)
                    }
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.hearthBody.weight(.medium))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(2)
                                Text(entry.stableId)
                                    .font(.hearthUI(11))
                                    .foregroundStyle(hearth.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            QuietButton(title: "Restore", systemImage: nil) {
                                restore([entry.stableId])
                            }
                        }
                    }
                }
                if isRestoring {
                    SourcesCard {
                        HStack(spacing: 10) {
                            ProgressView().tint(hearth.ember)
                            Text("Restoring. Refreshing your library.")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                    }
                }
            }
        }
        .confirmationDialog("Restore every book?", isPresented: $showingRestoreAll, titleVisibility: .visible) {
            Button("Restore all") { restore(entries.map(\.stableId)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All deleted books are restored and fetched again from their servers.")
        }
        .task {
            entries = engine.library.recentlyDeletedEntries()
        }
    }

    private func restore(_ stableIds: [String]) {
        guard !isRestoring, !stableIds.isEmpty else { return }
        isRestoring = true
        Task {
            await engine.library.restoreDeletedBooks(stableIds)
            entries = engine.library.recentlyDeletedEntries()
            isRestoring = false
            PlatformHaptics.notification(.success)
        }
    }
}
