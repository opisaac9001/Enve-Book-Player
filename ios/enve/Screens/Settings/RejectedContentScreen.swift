import SwiftUI

struct RejectedContentScreen: View {
    @Environment(\.hearth) private var hearth

    @State private var store = RejectedContentStore.shared
    @State private var showingClearAll = false

    var body: some View {
        SettingsScaffold(
            overline: "Library & content",
            title: "Rejected content",
            subtitle: store.entries.isEmpty ? nil : "\(store.entries.count) item\(store.entries.count == 1 ? "" : "s") could not be imported."
        ) {
            if store.entries.isEmpty {
                SourcesCard {
                    Text("Nothing has been rejected. If a source returns a broken item, Enve will list it here and continue importing everything else.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SourcesCard {
                    HStack {
                        Overline("Rejected")
                        Spacer()
                        Button("Clear all") { showingClearAll = true }
                            .font(.hearthCaption.weight(.medium))
                            .foregroundStyle(hearth.ember)
                    }

                    ForEach(store.entries) { entry in
                        rejectedRow(entry)
                    }
                }
            }
        }
        .confirmationDialog("Clear rejected content?", isPresented: $showingClearAll, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the list only. Enve will report an item again if a source still returns it in a broken format.")
        }
    }

    private func rejectedRow(_ entry: RejectedContentEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.providerType.iconName)
                .font(.hearthUI(15, weight: .medium))
                .foregroundStyle(hearth.statusWarn)
                .frame(width: 34, height: 34)
                .background(Circle().fill(hearth.statusWarn.opacity(0.14)))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title ?? "Unidentified item")
                    .font(.hearthBody.weight(.medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                Text("\(entry.sourceName) · Library \(entry.libraryId)")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(2)
                if let itemIdentifier = entry.itemIdentifier {
                    Text("Item ID: \(itemIdentifier)")
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(entry.reason)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Last rejected \(entry.lastRejectedAt.formatted(.relative(presentation: .named)))")
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textTertiary)
            }

            Spacer(minLength: 8)
            QuietButton(title: "Dismiss", systemImage: nil) {
                store.dismiss(id: entry.id)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
