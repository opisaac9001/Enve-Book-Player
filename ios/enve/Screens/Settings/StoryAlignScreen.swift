import SwiftUI
import UniformTypeIdentifiers

struct StoryAlignScreen: View {
    @Environment(\.hearth) private var hearth

    var body: some View {
        if #available(iOS 26.0, *) {
            StoryAlignHub()
        } else {
            SettingsScaffold(
                overline: "Library & content",
                title: "StoryAlign",
                subtitle: StoryAlignAvailability.unsupportedMessage
            ) {
                SourcesCard {
                    Text(
                        "Read-aloud alignment listens to the whole audiobook on-device and lines each sentence up with the text. The speech stack it needs arrives with iOS 26."
                    )
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

@available(iOS 26.0, *)
private struct StoryAlignHub: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    @State private var selectedEbook: Book?
    @State private var selectedAudiobook: Book?
    @State private var showEbookPicker = false
    @State private var showAudiobookPicker = false
    @State private var showStartWarning = false
    @State private var deleteCandidate: StoryAlignService.CompletedConversion?
    @State private var completed: [StoryAlignService.CompletedConversion] = []

    private var canStart: Bool {
        engine.storyAlign.canStart(ebook: selectedEbook, audiobook: selectedAudiobook)
    }

    var body: some View {
        SettingsScaffold(
            overline: "Library & content",
            title: "StoryAlign",
            subtitle: "Make read-aloud EPUBs: synced text, audio, and live highlighting."
        ) {
            pairCard
            if selectedEbook != nil || selectedAudiobook != nil { statusCard }
            if let state = engine.storyAlign.activeConversion { activeCard(state) }
            if let paused = engine.storyAlign.pausedConversion { pausedCard(paused) }
            if !completed.isEmpty { completedCard }
            aboutCard
        }
        .sheet(isPresented: $showEbookPicker) {
            StoryAlignBookPicker(title: "Choose the ebook", mediaType: "ebook", selection: $selectedEbook)
                .enveEnvironment()
        }
        .sheet(isPresented: $showAudiobookPicker) {
            StoryAlignBookPicker(title: "Choose the audiobook", mediaType: "audiobook", selection: $selectedAudiobook)
                .enveEnvironment()
        }
        .alert(StoryAlignLaunchWarning.title, isPresented: $showStartWarning) {
            Button("I understand") {
                guard let ebook = selectedEbook, let audiobook = selectedAudiobook else { return }
                engine.storyAlign.startConversion(ebook: ebook, audiobook: audiobook)
            }
            Button("Maybe later", role: .cancel) {}
        } message: {
            Text(StoryAlignLaunchWarning.message)
        }
        .confirmationDialog(
            "Delete this alignment?",
            isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
            titleVisibility: .visible,
            presenting: deleteCandidate
        ) { conversion in
            Button("Delete", role: .destructive) {
                engine.storyAlign.deleteConversion(ebook: conversion.ebook, audiobook: conversion.audiobook)
                completed.removeAll { $0.id == conversion.id }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { _ in
            Text("The read-aloud EPUB is removed. You can align the pair again any time.")
        }
        .task {
            for await conversions in engine.storyAlign.completedConversions() {
                if Task.isCancelled { break }
                completed = conversions
            }
        }
    }

    private var pairCard: some View {
        SourcesCard {
            Overline("The pair")
            HStack(alignment: .top, spacing: 14) {
                storyAlignSlot(label: "Ebook", glyph: "book", book: selectedEbook) { showEbookPicker = true }
                Image(systemName: "arrow.left.arrow.right")
                    .font(.hearthUI(13, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
                    .padding(.top, 44)
                storyAlignSlot(label: "Audiobook", glyph: "headphones", book: selectedAudiobook) { showAudiobookPicker = true }
            }
            .frame(maxWidth: .infinity)

            Text(
                "Pick both halves of one story. Enve downloads anything missing, aligns them, and shelves the read-aloud EPUB in your library."
            )
            .font(.hearthCaption)
            .foregroundStyle(hearth.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            startButton
        }
    }

    private func storyAlignSlot(label: String, glyph: String, book: Book?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if let book {
                    CoverTile(book: book, width: 84)
                    Text(book.title)
                        .font(.hearthCaption.weight(.medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: 92)
                } else {
                    RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                        .strokeBorder(hearth.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                        .frame(width: 84, height: 112)
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: glyph)
                                    .font(.hearthUI(20))
                                    .foregroundStyle(hearth.ember)
                                Text(label)
                                    .font(.hearthUI(11, weight: .semibold))
                                    .foregroundStyle(hearth.textSecondary)
                            }
                        }
                    Text("Tap to choose")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }
            }
        }
        .buttonStyle(PressableStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel(book.map { "\(label): \($0.title)" } ?? "Choose \(label)")
    }

    @ViewBuilder
    private var startButton: some View {
        let alreadyDone =
            selectedEbook.flatMap { ebook in
                selectedAudiobook.map { engine.storyAlign.isConverted(ebook: ebook, audiobook: $0) }
            } ?? false
        let isActive = engine.storyAlign.activeConversion != nil

        EmberButton(
            title: isActive ? "Aligning…" : (alreadyDone ? "Align again" : "Start alignment"),
            systemImage: isActive ? nil : "wand.and.stars",
            tint: nil
        ) {
            showStartWarning = true
        }
        .disabled(!canStart)
        .opacity(canStart ? 1 : 0.5)
    }

    private var statusCard: some View {
        let needs = selectedEbook.flatMap { ebook in
            selectedAudiobook.map { engine.storyAlign.needsDownload(ebook: ebook, audiobook: $0) }
        }
        return SourcesCard {
            Overline("Ready check")
            if let ebook = selectedEbook {
                storyAlignStatusRow(title: ebook.title, kind: "Ebook", needsDownload: needs?.ebook ?? false)
            }
            if let audiobook = selectedAudiobook {
                storyAlignStatusRow(title: audiobook.title, kind: "Audiobook", needsDownload: needs?.audiobook ?? false)
            }
        }
    }

    private func storyAlignStatusRow(title: String, kind: String, needsDownload: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: needsDownload ? "arrow.down.circle" : "checkmark.circle.fill")
                .foregroundStyle(needsDownload ? hearth.statusWarn : hearth.statusOK)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.hearthBody.weight(.medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                Text(kind)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
            Spacer()
            Text(needsDownload ? "Will download" : "Ready")
                .font(.hearthCaption)
                .foregroundStyle(needsDownload ? hearth.statusWarn : hearth.textTertiary)
        }
    }

    private func activeCard(_ state: StoryAlignService.ConversionState) -> some View {
        SourcesCard {
            Overline("In progress")
            HStack(spacing: 12) {
                if state.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.hearthUI(22))
                        .foregroundStyle(hearth.statusOK)
                } else if state.error != nil {
                    Image(systemName: "xmark.circle.fill")
                        .font(.hearthUI(22))
                        .foregroundStyle(hearth.statusError)
                } else {
                    ProgressView().tint(hearth.ember)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.stage)
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                    if !state.isComplete, state.error == nil {
                        Text(
                            state.isDownloadPhase && state.progress <= 0
                                ? "Downloading…"
                                : "\(Int(state.progress * 100))%\(state.detailText.map { " · \($0)" } ?? "")"
                        )
                        .font(.hearthCaption.monospacedDigit())
                        .foregroundStyle(hearth.textSecondary)
                    }
                }
                Spacer()
            }
            if !state.isComplete,
                state.error == nil,
                !state.isDownloadPhase || state.progress > 0
            {
                Ribbon(progress: state.progress, tint: hearth.ember)
            }
            if let error = state.error {
                SourcesErrorText(message: error)
            }
            if state.isComplete {
                if let elapsed = state.elapsedTime {
                    Text("Finished in \(HearthFormat.duration(elapsed))")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                QuietButton(title: "Done", systemImage: "checkmark") { engine.storyAlign.dismissConversion() }
            } else if state.error != nil {
                QuietButton(title: "Dismiss", systemImage: nil) { engine.storyAlign.dismissConversion() }
            } else {
                QuietButton(title: "Cancel", systemImage: nil) { engine.storyAlign.cancelConversion() }
            }
        }
    }

    private func pausedCard(_ paused: StoryAlignService.PausedConversion) -> some View {
        let books = engine.storyAlign.books(for: paused)
        let ebook = books.ebook
        let audiobook = books.audiobook
        return SourcesCard {
            Overline("Paused")
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill")
                    .font(.hearthUI(22))
                    .foregroundStyle(hearth.statusWarn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ebook?.title ?? "Unknown ebook")
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    Text("Interrupted by the system. Transcription progress is saved.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                if let ebook, let audiobook {
                    EmberButton(title: "Resume", systemImage: "play.fill", tint: nil) {
                        engine.storyAlign.resumeConversion(ebook: ebook, audiobook: audiobook)
                    }
                }
                QuietButton(title: "Discard", systemImage: nil) {
                    engine.storyAlign.cancelConversion()
                    if let ebook, let audiobook {
                        engine.storyAlign.deleteConversion(ebook: ebook, audiobook: audiobook)
                    }
                }
            }
        }
    }

    private var completedCard: some View {
        SourcesCard {
            Overline("Completed alignments")
            ForEach(completed) { pair in
                HStack(spacing: 10) {
                    CoverTile(book: pair.ebook, width: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.ebook.title)
                            .font(.hearthBody.weight(.medium))
                            .foregroundStyle(hearth.text)
                            .lineLimit(1)
                        Text("Narrated by \(pair.audiobook.title)")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    GlyphButton(systemImage: "trash", size: 36, glyphSize: 13, label: "Delete alignment for \(pair.ebook.title)") {
                        deleteCandidate = pair
                    }
                }
            }
        }
    }

    private var aboutCard: some View {
        SourcesCard {
            Overline("How it works")
            Text(
                "StoryAlign transcribes the audiobook with Apple's on-device speech stack and lines each sentence up with the ebook text, writing the result as media overlays inside a new EPUB. Open it from your library to read and listen at once, sentences lighting as they're spoken. Everything stays on this device."
            )
            .font(.hearthCaption)
            .foregroundStyle(hearth.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let storyAlignURL = URL(string: "https://codeberg.org/richwaters/StoryAlign") {
                    Link("StoryAlign", destination: storyAlignURL)
                }
                if let storytellerURL = URL(string: "https://gitlab.com/storyteller-platform/storyteller") {
                    Link("Storyteller", destination: storytellerURL)
                }
            }
            .font(.hearthCaption.weight(.medium))
            .foregroundStyle(hearth.ember)
        }
    }
}

@available(iOS 26.0, *)
private struct StoryAlignBookPicker: View {
    let title: String
    let mediaType: String
    @Binding var selection: Book?

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var books: [Book] = []
    @State private var canLoadMore = false
    @State private var isLoadingMore = false
    @State private var loaded = false
    @State private var showFileImporter = false
    @State private var isImporting = false
    @State private var importError: String?

    private var importContentTypes: [UTType] {
        mediaType == "ebook" ? [.epub, .pdf, .zip] : [.audio, .zip]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title)
                        .font(.hearthDisplay(24))
                        .foregroundStyle(hearth.text)
                    SourcesField(label: "Search", text: $query, placeholder: "Title or author")

                    if isImporting {
                        HStack(spacing: 10) {
                            ProgressView().tint(hearth.ember)
                            Text("Importing…")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                    }
                    if let importError { SourcesErrorText(message: importError) }

                    if !loaded {
                        HStack(spacing: 10) {
                            ProgressView().tint(hearth.ember)
                            Text("Looking through the shelves…")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                    } else if books.isEmpty {
                        Text(query.isEmpty ? "Nothing of this kind in the library yet." : "Nothing matches that search.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(books, id: \.stableId) { book in
                                Button {
                                    selection = book
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        CoverTile(book: book, width: 40)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(book.title)
                                                .font(.hearthBody.weight(.medium))
                                                .foregroundStyle(hearth.text)
                                                .lineLimit(2)
                                            if let author = book.author {
                                                Text(author)
                                                    .font(.hearthCaption)
                                                    .foregroundStyle(hearth.textSecondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        if selection?.stableId == book.stableId {
                                            Image(systemName: "checkmark")
                                                .font(.hearthUI(13, weight: .semibold))
                                                .foregroundStyle(hearth.ember)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PressableStyle())
                            }
                            if canLoadMore, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                QuietButton(title: isLoadingMore ? "Loading…" : "Load more", systemImage: nil) {
                                    loadNextPage()
                                }
                                .disabled(isLoadingMore)
                            }
                        }
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
                ToolbarItem(placement: .primaryAction) {
                    GlyphButton(systemImage: "square.and.arrow.down", size: 36, glyphSize: 14, label: "Import a file") {
                        showFileImporter = true
                    }
                    .disabled(isImporting)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: importContentTypes,
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .task(id: query) { await reload() }
        }
        .hearthPresentationBackground()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            isImporting = true
            importError = nil
            Task {
                do {
                    let newBook = try await engine.storyAlign.importFilesForPicker(urls: urls, mediaType: mediaType)
                    isImporting = false

                    if let newBook {
                        selection = newBook
                        dismiss()
                    } else {
                        await reload()
                    }
                } catch {
                    isImporting = false
                    importError = error.localizedDescription
                }
            }
        case let .failure(error):
            importError = error.localizedDescription
        }
    }

    private func reload() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = await engine.storyAlign.pickerPage(mediaType: mediaType, query: trimmed)
        guard !Task.isCancelled else { return }
        books = page.books
        canLoadMore = page.canLoadMore
        loaded = true
    }

    private func loadNextPage() {
        guard !isLoadingMore, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isLoadingMore = true
        let cursor = books.last
        Task {
            let page = await engine.storyAlign.pickerPage(mediaType: mediaType, query: query, after: cursor)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                books.append(contentsOf: page.books)
                canLoadMore = page.canLoadMore
            }
            isLoadingMore = false
        }
    }
}
