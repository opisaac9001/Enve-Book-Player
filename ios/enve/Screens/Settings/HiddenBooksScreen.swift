import SwiftUI

struct HiddenBooksScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    @State private var prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
    @State private var showingClearAll = false

    private var hiddenIds: [String] { prefs.hiddenBookIds.sorted() }

    var body: some View {
        SettingsScaffold(
            overline: "Library & content",
            title: "Hidden books",
            subtitle: hiddenIds.isEmpty ? nil : "\(hiddenIds.count) hidden from the library."
        ) {
            if hiddenIds.isEmpty {
                SourcesCard {
                    Text("Nothing is hidden. Long-press a cover in the library to tuck a book away.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SourcesCard {
                    HStack {
                        Overline("Hidden")
                        Spacer()
                        Button("Unhide all") { showingClearAll = true }
                            .font(.hearthCaption.weight(.medium))
                            .foregroundStyle(hearth.ember)
                    }
                    ForEach(hiddenIds, id: \.self) { stableId in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prefs.hiddenBookNames[stableId] ?? "Hidden book")
                                    .font(.hearthBody.weight(.medium))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(2)
                                Text(stableId)
                                    .font(.hearthUI(11))
                                    .foregroundStyle(hearth.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            QuietButton(title: "Unhide", systemImage: nil) {
                                unhide([stableId])
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Unhide every book?", isPresented: $showingClearAll, titleVisibility: .visible) {
            Button("Unhide all") { unhide(hiddenIds) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All hidden books return to the library.")
        }
    }

    private func unhide(_ stableIds: [String]) {
        prefs = SettingsPrefs.mutate { prefs in
            for id in stableIds {
                prefs.hiddenBookIds.remove(id)
                prefs.hiddenBookNames.removeValue(forKey: id)
            }
        }
        Task {
            await engine.library.restoreHiddenBooks(stableIds: stableIds)
        }
        PlatformHaptics.notification(.success)
    }
}
