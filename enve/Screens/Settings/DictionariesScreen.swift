import Combine
import SwiftUI
import UniformTypeIdentifiers

struct DictionariesScreen: View {
    @Environment(\.hearth) private var hearth

    @ObservedObject private var store = InstalledDictionariesStore.shared

    @State private var showingFolderPicker = false
    @State private var importError: String?
    @State private var lastInstalled: String?

    var body: some View {
        SettingsScaffold(
            overline: "Library & content",
            title: "Dictionaries",
            subtitle: "Offline lookups for Define. Without one, Enve falls back to the online service and Apple's dictionaries."
        ) {
            SourcesCard {
                QuietButton(title: "Add a dictionary…", systemImage: "plus.circle") {
                    showingFolderPicker = true
                }
                Text("Pick a StarDict folder. Free dictionaries live at stardict.sourceforge.net and freedict.org.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let lastInstalled {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(hearth.statusOK)
                        Text("Installed \u{201C}\(lastInstalled)\u{201D}")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
                if let importError { SourcesErrorText(message: importError) }
            }

            if store.dictionaries.isEmpty {
                SourcesCard {
                    Text("No dictionaries installed yet.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
            } else {
                SourcesCard {
                    Overline("Installed")
                    ForEach(store.dictionaries) { dictionary in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dictionary.displayName)
                                    .font(.hearthBody.weight(.medium))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(1)
                                Text("\(dictionary.wordCount.formatted()) entries")
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textSecondary)
                            }
                            Spacer()
                            GlyphButton(systemImage: "trash", glyphSize: 14, label: "Delete \(dictionary.displayName)") {
                                store.delete(dictionary)
                            }
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case .success(let urls):
            guard let folder = urls.first else { return }
            let didStart = folder.startAccessingSecurityScopedResource()
            defer { if didStart { folder.stopAccessingSecurityScopedResource() } }
            do {
                let installed = try store.installFromFolder(folderURL: folder)
                lastInstalled = installed.displayName
                PlatformHaptics.notification(.success)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}
