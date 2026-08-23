import SwiftUI
import UniformTypeIdentifiers

struct ObsidianScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    @State private var prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
    @State private var coordinator = ObsidianNotesCoordinator.shared
    @State private var showFolderPicker = false
    @State private var showTemplateEditor = false
    @State private var showResetConfirm = false
    @State private var isPreparingExport = false
    @State private var manualExportText: String?

    var body: some View {
        SettingsScaffold(
            overline: "Library & content",
            title: "Obsidian",
            subtitle: "Highlights and notes as Markdown. Share them anywhere, or write them into your vault."
        ) {
            manualExportCard

            SourcesCard {
                SourcesToggleRow(
                    title: "Sync to a vault folder",
                    subtitle: "One Markdown file per book, kept current as you highlight",
                    isOn: Binding(
                        get: { prefs.obsidianSyncEnabled },
                        set: { value in prefs = SettingsPrefs.mutate { $0.obsidianSyncEnabled = value } }
                    )
                )
            }

            if prefs.obsidianSyncEnabled {
                vaultCard
                behaviorCard
                templateCard
                statusCard
            }
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                coordinator.setVaultURL(url)
                prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
            }
        }
        .sheet(isPresented: $showTemplateEditor) {
            ObsidianTemplateEditor(prefs: $prefs) {
                LibraryDisplayPreferencesStore.shared.savePreferences(prefs)
            }
            .enveEnvironment()
        }
        .alert("Restore the default template?", isPresented: $showResetConfirm) {
            Button("Restore", role: .destructive) {
                prefs = SettingsPrefs.mutate {
                    $0.obsidianTemplateBody = UserPreferences.ObsidianDefaults.templateBody
                    $0.obsidianFilenameTemplate = UserPreferences.ObsidianDefaults.filenameTemplate
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your customized template is replaced with Enve's default.")
        }
    }

    private var manualExportCard: some View {
        SourcesCard {
            Overline("Manual export")
            Text(
                "Render every book's highlights, notes, and bookmark notes with your template, then send the Markdown to Files, Mail, AirDrop, or wherever it should go."
            )
            .font(.hearthCaption)
            .foregroundStyle(hearth.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if let manualExportText {
                ShareLink(item: manualExportText) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.hearthUI(15, weight: .semibold))
                        Text("Share the export")
                            .font(.hearthUI(16, weight: .semibold))
                    }
                    .foregroundStyle(hearth.onEmber)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(hearth.ember, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            } else {
                EmberButton(
                    title: isPreparingExport ? "Rendering…" : "Render the Markdown",
                    systemImage: isPreparingExport ? nil : "doc.text",
                    tint: nil
                ) {
                    guard !isPreparingExport else { return }
                    Task { await prepareManualExport() }
                }
                .disabled(isPreparingExport)
            }
        }
    }

    private var vaultCard: some View {
        SourcesCard {
            Overline("Vault folder")
            if prefs.obsidianVaultBookmarkData != nil {
                if coordinator.vaultBookmarkIsStale {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(hearth.statusWarn)
                        Text("Folder access expired. Choose the folder again.")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
                HStack(spacing: 10) {
                    QuietButton(title: "Change folder", systemImage: "folder") {
                        showFolderPicker = true
                    }
                    QuietButton(title: "Forget folder", systemImage: nil) {
                        coordinator.clearVault()
                        prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
                    }
                }
            } else {
                QuietButton(title: "Choose a vault folder…", systemImage: "folder.badge.plus") {
                    showFolderPicker = true
                }
            }
            SourcesField(
                label: "Subfolder",
                text: Binding(
                    get: { prefs.obsidianSubfolder },
                    set: { value in prefs = SettingsPrefs.mutate { $0.obsidianSubfolder = value } }
                ),
                placeholder: "Enve"
            )
        }
    }

    private var behaviorCard: some View {
        SourcesCard {
            Overline("Behavior")
            SourcesToggleRow(
                title: "Export automatically on changes",
                isOn: Binding(
                    get: { prefs.obsidianAutoExportEnabled },
                    set: { value in prefs = SettingsPrefs.mutate { $0.obsidianAutoExportEnabled = value } }
                )
            )
            SettingsMenuRow(title: "Update policy", value: prefs.obsidianUpdatePolicy.displayName) {
                ForEach(UserPreferences.ObsidianUpdatePolicy.allCases) { policy in
                    Button(policy.displayName) {
                        prefs = SettingsPrefs.mutate { $0.obsidianUpdatePolicy = policy }
                    }
                }
            }
            Text(prefs.obsidianUpdatePolicy.description)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            SourcesToggleRow(
                title: "Atomic highlights",
                subtitle: "One file per highlight instead of one per book",
                isOn: Binding(
                    get: { prefs.obsidianAtomicHighlights },
                    set: { value in prefs = SettingsPrefs.mutate { $0.obsidianAtomicHighlights = value } }
                )
            )
        }
    }

    private var templateCard: some View {
        SourcesCard {
            Overline("Template")
            QuietButton(title: "Edit template", systemImage: "doc.text.below.ecg") {
                showTemplateEditor = true
            }
            Button {
                showResetConfirm = true
            } label: {
                Label("Restore default template", systemImage: "arrow.uturn.backward")
                    .font(.hearthBody.weight(.medium))
                    .foregroundStyle(hearth.statusError)
            }
            Text(
                "Templates use Liquid-style syntax ({{ var }}, {% if %}, {% for %}). Highlights are tracked by id, so the Magic policy preserves anything you write between the markers."
            )
            .font(.hearthCaption)
            .foregroundStyle(hearth.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusCard: some View {
        SourcesCard {
            Overline("Status")
            if let success = coordinator.lastSuccessAt {
                HStack {
                    Text("Last sync")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                    Spacer()
                    Text(success.formatted(.relative(presentation: .named)))
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            HStack {
                Text("Books synced")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                Spacer()
                Text("\(prefs.obsidianLastSyncDates.count)")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
            if let error = coordinator.lastError {
                SourcesErrorText(message: error.localizedDescription)
            }
        }
    }

    private func prepareManualExport() async {
        isPreparingExport = true
        defer { isPreparingExport = false }

        manualExportText = await engine.journal.renderObsidianManualExport(preferences: prefs)
    }
}

private struct ObsidianTemplateEditor: View {
    @Binding var prefs: UserPreferences
    let onSave: () -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var workingTemplate = ""
    @State private var workingFilename = ""
    @State private var showPreview = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Template")
                        .font(.hearthDisplay(24))
                        .foregroundStyle(hearth.text)

                    HStack(spacing: 10) {
                        HearthChip(title: "Edit", isSelected: !showPreview) { showPreview = false }
                        HearthChip(title: "Preview", isSelected: showPreview) { showPreview = true }
                    }

                    if showPreview {
                        previewPane
                    } else {
                        editorPane
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(HearthBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(hearth.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        prefs.obsidianTemplateBody = workingTemplate
                        prefs.obsidianFilenameTemplate = workingFilename
                        onSave()
                        dismiss()
                    }
                    .foregroundStyle(hearth.ember)
                }
            }
        }
        .hearthPresentationBackground()
        .onAppear {
            workingTemplate = prefs.obsidianTemplateBody
            workingFilename = prefs.obsidianFilenameTemplate
        }
    }

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SourcesField(label: "Filename", text: $workingFilename)

            VStack(alignment: .leading, spacing: 7) {
                Overline("Body")
                TextEditor(text: $workingTemplate)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(hearth.text)
                    .frame(minHeight: 320)
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(hearth.bg)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(hearth.hairline, lineWidth: 1)
                            }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            SourcesCard {
                Overline("Variables")
                obsidianHelpRow("{{ book.title }}", "The book's title")
                obsidianHelpRow("{{ book.authors }}", "Array. Loop it, or use `| join: \", \"`")
                obsidianHelpRow("{{ book.series }} · {{ book.isbn }} · {{ book.asin }}", "Series and identifiers when known")
                obsidianHelpRow("{{ book.progress }}", "Reading progress, 0.0-1.0")
                obsidianHelpRow("{{ highlights }}", "Array. Use {% for h in highlights %}")
                obsidianHelpRow("{{ h.text }} / {{ h.note }} / {{ h.colorHex }}", "Per-highlight fields")
                obsidianHelpRow("{{ audiobookNotes }} · {{ ebookBookmarks }}", "Bookmark notes by format")
                obsidianHelpRow("{{ exportedAt | date: \"yyyy-MM-dd\" }}", "Format dates")
            }
        }
    }

    private func obsidianHelpRow(_ token: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(token)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(hearth.text)
            Text(caption)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Overline("Filename")
            Text(previewFilename)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(hearth.text)
            Divider().overlay(hearth.hairline)
            Overline("Rendered markdown")
            Text(previewMarkdown)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(hearth.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var previewPayload: BookNotesPayload {
        let now = Date()
        let book = BookNotesPayload.BookMeta(
            id: "preview:1",
            title: "Sample Book",
            authors: ["Jane Doe"],
            narrator: nil,
            series: "Sample Series",
            seriesNumber: "2",
            publishedYear: 2024,
            publisher: nil,
            isbn: "9780000000000",
            asin: nil,
            language: "en",
            genres: ["Fiction", "Adventure"],
            mediaType: "ebook",
            coverPath: nil,
            progress: 0.42
        )
        let highlights = [
            BookNotesPayload.HighlightItem(
                id: "h1",
                text: "The unexamined life is not worth living.",
                note: "Need to think about this more.",
                colorHex: "#FFF59D",
                style: "highlight",
                position: 0.12,
                chapterTitle: "Chapter 1",
                createdAt: now,
                updatedAt: now
            ),
            BookNotesPayload.HighlightItem(
                id: "h2",
                text: "We are what we repeatedly do.",
                note: nil,
                colorHex: "#A5D6A7",
                style: "highlight",
                position: 0.34,
                chapterTitle: "Chapter 2",
                createdAt: now,
                updatedAt: now
            ),
        ]
        let audiobookNotes = [
            BookNotesPayload.AudiobookNote(
                id: "ab1",
                title: "Important moment",
                note: "The big reveal.",
                timestampSeconds: 3645,
                formattedTime: "1:00:45",
                chapterTitle: "Chapter 3",
                createdAt: now
            )
        ]
        return BookNotesPayload(
            book: book,
            highlights: highlights,
            audiobookNotes: audiobookNotes,
            ebookBookmarks: [],
            chapters: ["Chapter 1", "Chapter 2", "Chapter 3"],
            exportedAt: now,
            lastSyncedAt: nil
        )
    }

    private var previewMarkdown: String {
        NotesTemplateEngine.render(template: workingTemplate, payload: previewPayload)
    }

    private var previewFilename: String {
        let payload = previewPayload
        let values: [String: NotesTemplateEngine.TemplateValue] = [
            "book": .dict([
                "id": .string(payload.book.id),
                "title": .string(payload.book.title),
                "authors": .array(payload.book.authors.map { .string($0) }),
                "mediaType": .string(payload.book.mediaType),
            ])
        ]
        var name = NotesTemplateEngine.render(template: workingFilename, with: values)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Untitled.md" }
        if !name.lowercased().hasSuffix(".md") { name += ".md" }
        return name
    }
}
