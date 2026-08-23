import SwiftUI

struct KOReaderLinksScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    private var service: KOReaderSyncService { .shared }

    @State private var searchText = ""
    @State private var allEbooks: [Book] = []
    @State private var loaded = false
    @State private var editing: Book?

    private var ebooks: [Book] {
        guard !searchText.isEmpty else { return allEbooks }
        let query = searchText.lowercased()
        return allEbooks.filter {
            $0.title.lowercased().contains(query) || ($0.author?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        SettingsScaffold(
            overline: "KOReader",
            title: "Linked books",
            subtitle: "Each link pairs an ebook with the hash KOReader knows it by."
        ) {
            SourcesField(label: "Search", text: $searchText, placeholder: "Title or author")

            if !loaded {
                SourcesCard {
                    HStack(spacing: 10) {
                        ProgressView().tint(hearth.ember)
                        Text("Gathering your ebooks…")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
            } else if ebooks.isEmpty {
                SourcesCard {
                    Text(searchText.isEmpty ? "No ebooks yet." : "Nothing matches that search.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
            } else {
                SourcesCard {
                    ForEach(ebooks, id: \.stableId) { book in
                        koreaderLinkRow(book)
                    }
                }
            }
        }
        .task {
            for await fetched in engine.library.observedBooks(mediaType: AppMediaType.ebook.rawValue) {
                if Task.isCancelled { break }
                allEbooks = fetched
                loaded = true
            }
        }
        .sheet(item: $editing) { book in
            KOReaderLinkEditorSheet(book: book)
                .enveEnvironment()
        }
    }

    private func koreaderLinkRow(_ book: Book) -> some View {
        let link = service.link(for: book.stableId)
        return Button {
            editing = book
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    if let author = book.author, !author.isEmpty {
                        Text(author)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                    if let link {
                        HStack(spacing: 5) {
                            Image(systemName: link.isAutomatic ? "wand.and.stars" : "link")
                                .font(.hearthUI(10))
                            Text(link.documentHash.prefix(10) + "…")
                                .font(.hearthUI(11).monospaced())
                            if let pct = link.lastSyncedPercentage {
                                Text(String(format: "%.0f%% synced", pct * 100))
                                    .font(.hearthUI(11))
                            }
                        }
                        .foregroundStyle(hearth.textTertiary)
                    } else {
                        Text("Not linked")
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                    }
                }
                Spacer()
                Image(systemName: link != nil ? "link.circle.fill" : "link.badge.plus")
                    .font(.hearthUI(19))
                    .foregroundStyle(link != nil ? hearth.ember : hearth.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Edit KOReader link for \(book.title)")
    }
}

private struct KOReaderLinkEditorSheet: View {
    let book: Book

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    private var service: KOReaderSyncService { .shared }

    @State private var hashInput = ""
    @State private var isComputing = false
    @State private var computeError: String?

    private var hasLocalFile: Bool {
        EbookChapterSyncService.shared.resolvedFileURL(for: book) != nil
    }

    private var isValidHash: Bool {
        let trimmed = hashInput.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.count == 32 && trimmed.allSatisfy(\.isHexDigit)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Overline("Link book")
                        Text(book.title)
                            .font(.hearthDisplay(24))
                            .foregroundStyle(hearth.text)
                            .lineLimit(2)
                        if let author = book.author {
                            Text(author)
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                    }

                    SourcesCard {
                        SourcesField(label: "Document hash", text: $hashInput, placeholder: "32-character MD5")
                        if let computeError { SourcesErrorText(message: computeError) }
                        QuietButton(
                            title: isComputing ? "Computing…" : "Compute from local file",
                            systemImage: "doc.badge.gearshape"
                        ) {
                            Task { await computeFromFile() }
                        }
                        .disabled(isComputing || !hasLocalFile)
                        .opacity(hasLocalFile ? 1 : 0.5)
                        Text(
                            "Open the book in KOReader > Book Information to find its hash. Paste it here to sync progress even when files differ between devices."
                        )
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    EmberButton(title: "Save link", systemImage: "checkmark", tint: nil) {
                        service.link(book: book, documentHash: hashInput, isAutomatic: false)
                        PlatformHaptics.notification(.success)
                        dismiss()
                    }
                    .disabled(!isValidHash)
                    .opacity(isValidHash ? 1 : 0.5)

                    if service.link(for: book.stableId) != nil {
                        Button {
                            service.unlink(bookStableId: book.stableId)
                            dismiss()
                        } label: {
                            Label("Remove link", systemImage: "trash")
                                .font(.hearthBody.weight(.medium))
                                .foregroundStyle(hearth.statusError)
                        }
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .background(HearthBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(hearth.textSecondary)
                }
            }
        }
        .hearthPresentationBackground()
        .onAppear {
            if let existing = service.link(for: book.stableId) {
                hashInput = existing.documentHash
            }
        }
    }

    private func computeFromFile() async {
        guard let url = EbookChapterSyncService.shared.resolvedFileURL(for: book) else { return }
        computeError = nil
        isComputing = true
        defer { isComputing = false }
        if let hash = await KOReaderSyncService.computePartialMD5(fileURL: url) {
            hashInput = hash
        } else {
            computeError = "Couldn't read the local ebook file."
        }
    }
}
