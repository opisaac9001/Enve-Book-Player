#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct BookOrbitBookDropScreen: View {
    let connectionId: UUID

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var model: BookOrbitBookDropModel
    @State private var importing = false
    @State private var reviewing: BookOrbitProvider.BookDockFile?
    @State private var pendingDiscard: [BookOrbitProvider.BookDockFile] = []
    @State private var pendingApproval: [BookOrbitProvider.BookDockFile] = []
    @State private var choosingDestination = false
    @State private var approvalAfterReview: Int?

    init(connectionId: UUID) {
        self.connectionId = connectionId
        _model = State(initialValue: BookOrbitBookDropModel(source: BookOrbitAccess.provider(connectionId)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                content
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + (model.isSelecting ? 96 : 16))
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .accessibilityIdentifier("bookorbit-drop-screen")
        .overlay(alignment: .bottom) {
            if model.isSelecting {
                selectionBar
                    .padding(.bottom, mantelInset + 10)
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .task(id: model.search) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            model.searchChanged()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                await model.upload(fileURL: url)
            }
        }
        .sheet(item: $reviewing, onDismiss: {
            guard let id = approvalAfterReview else { return }
            approvalAfterReview = nil
            Task { await model.finalize(ids: [id]) }
        }) { file in
            BookOrbitBookDropFileSheet(model: model, file: file) { id in
                approvalAfterReview = id
                reviewing = nil
            }
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .sheet(isPresented: $choosingDestination) {
            BookOrbitBookDropDestinationSheet(model: model, ids: Array(model.selection))
                .enveEnvironment()
                .hearthPresentationBackground()
                .presentationDetents([.medium, .large])
        }
        .sheet(
            isPresented: Binding(
                get: { model.finalizeResult != nil },
                set: { if !$0 { model.finalizeResult = nil } }
            )
        ) {
            if let result = model.finalizeResult {
                BookOrbitBookDropResultSheet(result: result)
                    .enveEnvironment()
                    .hearthPresentationBackground()
                    .presentationDetents([.medium, .large])
            }
        }
        .confirmationDialog(
            pendingDiscard.count == 1 ? "Discard this file?" : "Discard \(pendingDiscard.count) files?",
            isPresented: Binding(get: { !pendingDiscard.isEmpty }, set: { if !$0 { pendingDiscard = [] } }),
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                let ids = pendingDiscard.map(\.id)
                Task { await model.discard(ids: ids) }
            }
            .accessibilityIdentifier("bookorbit-drop-confirm-discard")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("BookOrbit removes the staged upload from its Book Drop. Nothing already in a library is touched.")
        }
        .confirmationDialog(
            pendingApproval.count == 1 ? "File this book into its library?" : "File \(pendingApproval.count) books into their libraries?",
            isPresented: Binding(get: { !pendingApproval.isEmpty }, set: { if !$0 { pendingApproval = [] } }),
            titleVisibility: .visible
        ) {
            Button("Approve") {
                let ids = pendingApproval.map(\.id)
                Task { await model.finalize(ids: ids) }
            }
            .accessibilityIdentifier("bookorbit-drop-confirm-approve")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("BookOrbit moves each file into the library and folder chosen for it.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            JournalScreenHeader(overline: "Staged on your server", title: "Book Drop")
            Spacer(minLength: 8)
            if model.state == .ready {
                if model.isUploading {
                    ProgressView()
                        .tint(hearth.ember)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Uploading")
                }
                GlyphButton(systemImage: "plus", label: "Add a file to the Book Drop") { importing = true }
                    .disabled(model.isUploading)
                    .accessibilityIdentifier("bookorbit-drop-import")
                GlyphButton(
                    systemImage: model.isSelecting ? "checkmark.circle.fill" : "checkmark.circle",
                    prominent: model.isSelecting,
                    label: model.isSelecting ? "Done choosing" : "Choose files"
                ) {
                    model.toggleSelecting()
                }
                .accessibilityIdentifier("bookorbit-drop-select")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            JournalLoadingNote(text: "Opening the Book Drop…")
        case .unavailable:
            BookOrbitUnavailableCard(line: "This BookOrbit server doesn't offer a Book Drop. Update the server to stage uploads here.")
        case .denied(let message):
            SourcesCard {
                Label("No Library Dock access", systemImage: "lock")
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Text(message)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                QuietButton(title: "Check again", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bookorbit-drop-denied")
        case .failed(let message):
            BookOrbitErrorCard(message: message) {
                Task { await model.load() }
            }
            .accessibilityIdentifier("bookorbit-drop-error")
        case .ready:
            ready
        }
    }

    @ViewBuilder
    private var ready: some View {
        if let notice = model.notice {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(notice.text)
                    .font(.hearthUI(13))
                    .foregroundStyle(notice.isError ? hearth.statusError : hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Dismiss") { model.notice = nil }
                    .font(.hearthUI(13, weight: .medium))
                    .tint(hearth.ember)
                    .frame(minHeight: 44)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bookorbit-drop-notice")
        }
        if !model.canFinalize {
            Text("Your account can stage and edit uploads. Filing them into a library needs the Upload books permission, so a Library Dock manager approves them.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bookorbit-drop-approval-unavailable")
        }
        if let summary = model.summary {
            Text(summaryLine(summary))
                .font(.hearthCaption.monospacedDigit())
                .foregroundStyle(hearth.textTertiary)
                .accessibilityIdentifier("bookorbit-drop-summary")
        }
        searchField
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(BookOrbitBookDropModel.Filter.allCases) { filter in
                    HearthChip(title: filter.title, isSelected: model.filter == filter) { model.select(filter) }
                        .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
                        .accessibilityIdentifier("bookorbit-drop-filter-\(filter.rawValue)")
                }
            }
        }
        .scrollIndicators(.hidden)
        if let message = model.refreshError {
            BookOrbitErrorCard(message: "Couldn't refresh the Book Drop. \(message)") {
                Task { await model.reload() }
            }
            .accessibilityIdentifier("bookorbit-drop-refresh-error")
        }
        if model.files.isEmpty {
            if model.isReloading {
                JournalLoadingNote(text: "Opening the Book Drop…")
            } else {
                JournalQuietNote(text: emptyText)
                    .accessibilityIdentifier("bookorbit-drop-empty")
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.files) { file in
                    row(file)
                        .onAppear {
                            guard file.id == model.files.last?.id else { return }
                            Task { await model.loadMore() }
                        }
                }
                pageFooter
            }
        }
    }

    private var emptyText: String {
        if !model.search.isEmpty { return "No staged file answers to that name." }
        return model.filter == .all ? "The Book Drop is empty. Add a file to stage it for a library." : "No staged files in this state."
    }

    private func summaryLine(_ summary: BookOrbitProvider.BookDockSummary) -> String {
        var parts = ["\(summary.total) staged", "\(summary.ready) ready", "\(summary.pending) processing"]
        if summary.error > 0 { parts.append("\(summary.error) failed") }
        if summary.paused == true { parts.append("processing paused") }
        return parts.joined(separator: " · ")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.hearthUI(14))
                .foregroundStyle(hearth.textTertiary)
            TextField("Search staged files", text: $model.search)
                .font(.hearthUI(15))
                .foregroundStyle(hearth.text)
                .autocorrectionDisabled()
                .accessibilityIdentifier("bookorbit-drop-search")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                )
        }
    }

    private func row(_ file: BookOrbitProvider.BookDockFile) -> some View {
        let metadata = file.metadata
        let busy = model.isBusy([file.id])
        return Button {
            if model.isSelecting {
                model.toggleSelected(file.id)
            } else {
                reviewing = file
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if model.isSelecting {
                    LibrarySelectionCircle(isSelected: model.selection.contains(file.id))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(metadata.title ?? file.fileName)
                        .font(.hearthDisplay(16, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    if let authors = metadata.authors, !authors.isEmpty {
                        Text(authors.joined(separator: ", "))
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(2)
                    }
                    Text(BookOrbitBookDropFormat.status(file))
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(statusColor(file))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detailLine(file))
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView()
                        .tint(hearth.ember)
                } else if !model.isSelecting {
                    Image(systemName: "chevron.right")
                        .font(.hearthUI(12, weight: .semibold))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(busy)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(model.isSelecting && model.selection.contains(file.id) ? .isSelected : [])
        .accessibilityHint(model.isSelecting ? "Double tap to change selection" : "Double tap to review")
        .accessibilityIdentifier("bookorbit-drop-file-\(file.id)")
    }

    private func statusColor(_ file: BookOrbitProvider.BookDockFile) -> Color {
        switch file.status {
        case "error": hearth.statusError
        case "ready": file.holdReason == nil ? hearth.statusOK : hearth.statusWarn
        default: hearth.textSecondary
        }
    }

    private func detailLine(_ file: BookOrbitProvider.BookDockFile) -> String {
        var parts = [file.fileName]
        if let format = file.format { parts.append(format.uppercased()) }
        if let size = file.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let alsoIn = file.alsoIn, !alsoIn.isEmpty { parts.append("Also in \(alsoIn.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var pageFooter: some View {
        if model.isLoadingMore {
            JournalLoadingNote(text: "Turning the page…")
        } else if let message = model.pageError {
            BookOrbitErrorCard(message: message) {
                Task { await model.loadMore(retry: true) }
            }
            .accessibilityIdentifier("bookorbit-drop-page-error")
        } else if model.hasMore {
            QuietButton(title: "Load more", systemImage: "arrow.down") {
                Task { await model.loadMore() }
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("bookorbit-drop-load-more")
        }
    }

    private var selectionBar: some View {
        let chosen = model.selectedFiles
        let ids = chosen.map(\.id)
        let idle = !chosen.isEmpty && !model.isBusy(ids)
        return HStack(spacing: 4) {
            Text("\(chosen.count) chosen")
                .font(.hearthUI(13, weight: .semibold))
                .foregroundStyle(hearth.text)
            Spacer(minLength: 8)
            barButton("folder", label: "Choose a destination for the chosen files", enabled: idle) {
                choosingDestination = true
            }
            .accessibilityIdentifier("bookorbit-drop-bulk-destination")
            barButton("wand.and.stars", label: "Apply fetched metadata to the chosen files", enabled: idle) {
                Task { await model.applyFetched(ids: ids) }
            }
            .accessibilityIdentifier("bookorbit-drop-bulk-apply")
            barButton("checkmark.seal", label: "Approve the chosen files", enabled: idle && model.canFinalize) {
                pendingApproval = chosen
            }
            .accessibilityIdentifier("bookorbit-drop-bulk-approve")
            barButton("trash", label: "Discard the chosen files", enabled: idle) {
                pendingDiscard = chosen
            }
            .accessibilityIdentifier("bookorbit-drop-bulk-discard")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background {
            HearthChromeBackground(
                shape: .rounded(22),
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: hearth.bgElevated,
                shadow: true
            )
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 20)
    }

    private func barButton(_ systemImage: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.hearthUI(17, weight: .medium))
                .foregroundStyle(enabled ? hearth.text : hearth.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private struct BookOrbitBookDropFileSheet: View {
    let model: BookOrbitBookDropModel
    @State var file: BookOrbitProvider.BookDockFile
    let approve: (Int) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var subtitle = ""
    @State private var authors = ""
    @State private var narrators = ""
    @State private var seriesName = ""
    @State private var seriesIndex = ""
    @State private var year = ""
    @State private var publisher = ""
    @State private var language = ""
    @State private var isbn13 = ""
    @State private var genres = ""
    @State private var summary = ""
    @State private var libraryId: Int?
    @State private var folderId: Int?
    @State private var confirmDiscard = false
    @State private var confirmApprove = false

    private var busy: Bool { model.isBusy([file.id]) }
    private var library: BookOrbitProvider.BookDockDestination? { model.destinations.first { $0.id == libraryId } }
    private var target: (libraryId: Int, folderId: Int)? {
        guard let libraryId, let folderId else { return nil }
        return (libraryId, folderId)
    }

    private var edited: BookOrbitProvider.BookDockMetadata {
        var metadata = file.metadata
        metadata.title = Self.text(title)
        metadata.subtitle = Self.text(subtitle)
        metadata.authors = Self.list(authors, previous: file.metadata.authors)
        metadata.narrators = Self.list(narrators, previous: file.metadata.narrators)
        metadata.seriesName = Self.text(seriesName)
        metadata.seriesIndex = Self.text(seriesIndex)
        metadata.publishedYear = Int(year.trimmingCharacters(in: .whitespaces))
        metadata.publisher = Self.text(publisher)
        metadata.language = Self.text(language)
        metadata.isbn13 = Self.text(isbn13)
        metadata.genres = Self.list(genres, previous: file.metadata.genres)
        metadata.description = Self.text(summary)
        return metadata
    }

    private var hasChanges: Bool {
        !edited.changes(from: file.metadata).isEmpty
            || (target != nil && (libraryId != file.targetLibraryId || folderId != file.targetFolderId))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    if file.fetchedMetadata != nil || file.embeddedMetadata != nil {
                        sourcesCard
                    }
                    metadataCard
                    destinationCard
                    actionsCard
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(file.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(busy || !hasChanges)
                        .accessibilityIdentifier("bookorbit-drop-save")
                }
            }
        }
        .onAppear(perform: populate)
        .confirmationDialog("Discard this file?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                Task {
                    await model.discard(ids: [file.id])
                    if !model.files.contains(where: { $0.id == file.id }) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("BookOrbit removes the staged upload from its Book Drop. Nothing already in a library is touched.")
        }
        .confirmationDialog("File this book into its library?", isPresented: $confirmApprove, titleVisibility: .visible) {
            Button("Approve") {
                Task {
                    if hasChanges, await model.save(file, metadata: edited, target: target) == nil { return }
                    approve(file.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(hasChanges ? "Your changes are saved first, then BookOrbit files the book." : "BookOrbit moves the file into the chosen library and folder.")
        }
    }

    private var statusCard: some View {
        SourcesCard {
            Text(BookOrbitBookDropFormat.status(file))
                .font(.hearthUI(15, weight: .semibold))
                .foregroundStyle(file.status == "error" ? hearth.statusError : hearth.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bookorbit-drop-file-status")
            if let confidence = file.confidence {
                AdminInfoRow(label: "Match confidence", value: "\(Int(confidence.rounded()))%")
            }
            if file.metadataEditedAt != nil {
                AdminInfoRow(label: "Metadata", value: "Edited by hand")
            }
            if let notice = model.notice {
                Text(notice.text)
                    .font(.hearthUI(13))
                    .foregroundStyle(notice.isError ? hearth.statusError : hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("bookorbit-drop-file-notice")
            }
        }
    }

    private var sourcesCard: some View {
        SourcesCard {
            Overline("What BookOrbit found")
            AdminInfoRow(label: "In the file", value: Self.brief(file.embeddedMetadata))
            AdminInfoRow(label: "Fetched", value: Self.brief(file.fetchedMetadata))
            HStack(spacing: 10) {
                QuietButton(title: "Apply fetched", systemImage: "wand.and.stars") {
                    Task {
                        await model.applyFetched(ids: [file.id])
                        refreshFromModel()
                    }
                }
                .disabled(busy || file.fetchedMetadata == nil)
                .accessibilityIdentifier("bookorbit-drop-apply-fetched")
                QuietButton(title: "Fetch again", systemImage: "arrow.clockwise") {
                    Task {
                        await model.refetch(id: file.id)
                        refreshFromModel()
                    }
                }
                .disabled(busy || !file.isSettled)
                .accessibilityIdentifier("bookorbit-drop-refetch")
            }
        }
    }

    private var metadataCard: some View {
        SourcesCard {
            Overline("Metadata to file with")
            SourcesField(label: "Title", text: $title)
                .accessibilityIdentifier("bookorbit-drop-field-title")
            SourcesField(label: "Subtitle", text: $subtitle)
            SourcesField(label: "Authors", text: $authors, placeholder: "Separate names with commas")
                .accessibilityIdentifier("bookorbit-drop-field-authors")
            SourcesField(label: "Narrators", text: $narrators, placeholder: "Separate names with commas")
            SourcesField(label: "Series", text: $seriesName)
            SourcesField(label: "Number in series", text: $seriesIndex, keyboard: .numbersAndPunctuation)
            SourcesField(label: "Year", text: $year, keyboard: .numberPad)
            SourcesField(label: "Publisher", text: $publisher)
            SourcesField(label: "Language", text: $language)
            SourcesField(label: "ISBN-13", text: $isbn13, keyboard: .numbersAndPunctuation)
            SourcesField(label: "Genres", text: $genres, placeholder: "Separate genres with commas")
            VStack(alignment: .leading, spacing: 7) {
                Overline("Description")
                TextField("", text: $summary, axis: .vertical)
                    .lineLimit(3...10)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background {
                        HearthChromeBackground(shape: .rounded(12), fill: hearth.bg, stroke: hearth.hairline, tint: hearth.bgElevated)
                    }
            }
        }
        .disabled(busy)
    }

    private var destinationCard: some View {
        SourcesCard {
            Overline("Destination")
            if let message = model.destinationsError {
                Text("Couldn't load the libraries. \(message)")
                    .font(.hearthUI(13))
                    .foregroundStyle(hearth.statusError)
                    .fixedSize(horizontal: false, vertical: true)
                QuietButton(title: "Try again", systemImage: "arrow.clockwise") {
                    Task { await model.loadDestinations() }
                }
            } else {
                BookOrbitBookDropDestinationPicker(destinations: model.destinations, libraryId: $libraryId, folderId: $folderId)
                if library != nil, folderId == nil {
                    Text("Choose the folder BookOrbit files into.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.statusWarn)
                }
            }
        }
        .disabled(busy)
    }

    private var actionsCard: some View {
        SourcesCard {
            if busy {
                AdminLoadingRow("Working with BookOrbit…")
            }
            QuietButton(title: "Approve and file", systemImage: "checkmark.seal") { confirmApprove = true }
                .disabled(busy || !model.canFinalize || file.status != "ready" || target == nil)
                .accessibilityIdentifier("bookorbit-drop-approve")
            if !model.canFinalize {
                Text("Filing needs the Upload books permission on this BookOrbit account.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            } else if file.status != "ready" {
                Text("BookOrbit can file this once it has finished reading it.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            } else if target == nil {
                Text("Choose a library and folder first.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
            Button(role: .destructive) {
                confirmDiscard = true
            } label: {
                Label("Discard from the Book Drop", systemImage: "trash")
                    .font(.hearthUI(15, weight: .medium))
                    .frame(minHeight: 44)
            }
            .disabled(busy)
            .accessibilityIdentifier("bookorbit-drop-discard")
        }
    }

    private func populate() {
        let metadata = file.metadata
        title = metadata.title ?? ""
        subtitle = metadata.subtitle ?? ""
        authors = (metadata.authors ?? []).joined(separator: ", ")
        narrators = (metadata.narrators ?? []).joined(separator: ", ")
        seriesName = metadata.seriesName ?? ""
        seriesIndex = metadata.seriesIndex ?? ""
        year = metadata.publishedYear.map(String.init) ?? ""
        publisher = metadata.publisher ?? ""
        language = metadata.language ?? ""
        isbn13 = metadata.isbn13 ?? ""
        genres = (metadata.genres ?? []).joined(separator: ", ")
        summary = metadata.description ?? ""
        libraryId = file.targetLibraryId
        folderId = file.targetFolderId
    }

    private func save() {
        Task {
            guard let saved = await model.save(file, metadata: edited, target: target) else { return }
            file = saved
            populate()
        }
    }

    private func refreshFromModel() {
        guard let latest = model.files.first(where: { $0.id == file.id }) else { return }
        file = latest
        populate()
    }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An untouched empty field stays absent instead of becoming an explicit empty list.
    private static func list(_ value: String, previous: [String]?) -> [String]? {
        let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return items.isEmpty && previous == nil ? nil : items
    }

    private static func brief(_ metadata: BookOrbitProvider.BookDockMetadata?) -> String {
        guard let metadata else { return "Nothing" }
        let parts = [metadata.title, metadata.authors?.joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "No title or author" : parts.joined(separator: " · ")
    }
}

private struct BookOrbitBookDropDestinationPicker: View {
    let destinations: [BookOrbitProvider.BookDockDestination]
    @Binding var libraryId: Int?
    @Binding var folderId: Int?

    @Environment(\.hearth) private var hearth

    private var library: BookOrbitProvider.BookDockDestination? { destinations.first { $0.id == libraryId } }

    var body: some View {
        Picker("Library", selection: $libraryId) {
            Text("Not chosen").tag(Int?.none)
            ForEach(destinations) { destination in
                Text(destination.name).tag(Int?.some(destination.id))
            }
        }
        .accessibilityIdentifier("bookorbit-drop-library")
        .onChange(of: libraryId) { _, _ in
            let folders = library?.folders ?? []
            if !folders.contains(where: { $0.id == folderId }) {
                folderId = folders.count == 1 ? folders.first?.id : nil
            }
        }
        if let library {
            if library.folders.isEmpty {
                Text("This library has no folders to file into.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusWarn)
            } else {
                Picker("Folder", selection: $folderId) {
                    Text("Not chosen").tag(Int?.none)
                    ForEach(library.folders) { folder in
                        Text(folder.path).tag(Int?.some(folder.id))
                    }
                }
                .accessibilityIdentifier("bookorbit-drop-folder")
            }
        }
    }
}

private struct BookOrbitBookDropDestinationSheet: View {
    let model: BookOrbitBookDropModel
    let ids: [Int]

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var libraryId: Int?
    @State private var folderId: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                SourcesCard {
                    Overline(ids.count == 1 ? "Destination for 1 file" : "Destination for \(ids.count) files")
                    if let message = model.destinationsError {
                        Text("Couldn't load the libraries. \(message)")
                            .font(.hearthUI(13))
                            .foregroundStyle(hearth.statusError)
                            .fixedSize(horizontal: false, vertical: true)
                        QuietButton(title: "Try again", systemImage: "arrow.clockwise") {
                            Task { await model.loadDestinations() }
                        }
                    } else {
                        BookOrbitBookDropDestinationPicker(destinations: model.destinations, libraryId: $libraryId, folderId: $folderId)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        guard let libraryId, let folderId else { return }
                        Task { await model.setTarget(ids: ids, libraryId: libraryId, folderId: folderId) }
                        dismiss()
                    }
                    .disabled(libraryId == nil || folderId == nil || model.isBusy(ids))
                    .accessibilityIdentifier("bookorbit-drop-set-destination")
                }
            }
        }
    }
}

private struct BookOrbitBookDropResultSheet: View {
    let result: BookOrbitProvider.BookDockFinalizeResult

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    private var headline: String {
        if result.failed == 0 { return result.succeeded == 1 ? "1 book filed" : "\(result.succeeded) books filed" }
        if result.succeeded == 0 { return result.failed == 1 ? "The book was not filed" : "None of the \(result.failed) books were filed" }
        return "\(result.succeeded) filed, \(result.failed) not filed"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(headline)
                        .font(.hearthDisplay(22))
                        .foregroundStyle(hearth.text)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("bookorbit-drop-result-headline")
                    ForEach(result.results) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(item.success ? hearth.statusOK : hearth.statusError)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.fileName)
                                    .font(.hearthUI(15, weight: .medium))
                                    .foregroundStyle(hearth.text)
                                Text(BookOrbitBookDropFormat.outcome(item))
                                    .font(.hearthCaption)
                                    .foregroundStyle(item.success ? hearth.textSecondary : hearth.statusError)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("bookorbit-drop-result-\(item.fileId)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("Book Drop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
