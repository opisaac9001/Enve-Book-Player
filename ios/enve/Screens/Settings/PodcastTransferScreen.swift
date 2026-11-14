#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct PodcastTransferScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(PodcastsModel.self) private var podcasts
    @Environment(\.hearth) private var hearth

    @State private var importPhase: ImportPhase = .idle
    @State private var selection: Set<String> = []
    @State private var isPickingFile = false
    @State private var importTask: Task<Void, Never>?

    @State private var includeProgress = true
    @State private var includePrivateFeeds = false
    @State private var exportPhase: ExportPhase = .idle
    @State private var exportFile: PodcastOPMLFile?
    @State private var isExporting = false
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        SettingsScaffold(
            overline: "Podcasts",
            title: "Move your shows",
            subtitle: "Bring subscriptions and listening history from another app with an OPML file, or take yours elsewhere."
        ) {
            importSection
            exportSection
        }
        .accessibilityIdentifier("podcast-transfer-screen")
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: PodcastOPMLFile.importTypes) { result in
            switch result {
            case .success(let url):
                read(url)
            case .failure(let error):
                guard !Self.isUserCancellation(error) else { return }
                importPhase = .failed(PodcastOPMLError.unreadable.localizedDescription)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportFile,
            contentType: PodcastOPMLFile.opml,
            defaultFilename: "Enve Podcasts.opml"
        ) { result in
            exportFile = nil
            switch result {
            case .success:
                if case .ready(let prepared) = exportPhase { exportPhase = .saved(prepared) }
            case .failure(let error):
                exportPhase = Self.isUserCancellation(error) ? .idle : .failed(error.localizedDescription)
            }
        }
        .onDisappear {
            importTask?.cancel()
            exportTask?.cancel()
        }
    }

    @ViewBuilder
    private var importSection: some View {
        Overline("Import")
            .accessibilityAddTraits(.isHeader)
        switch importPhase {
        case .idle:
            SourcesCard {
                Text("Export an OPML file from Overcast, Pocket Casts, Castro, or another podcast app, then choose it here. You'll see what's inside before anything changes. Overcast's full export also carries played and in-progress episodes.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                EmberButton(title: "Choose OPML file", systemImage: "doc.badge.plus") { isPickingFile = true }
                    .accessibilityIdentifier("podcast-transfer-choose-file")
            }
        case .reading:
            progressCard("Reading the file…", cancel: cancelImport)
        case .failed(let message):
            SourcesCard {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.statusError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("podcast-transfer-error")
                QuietButton(title: "Choose another file", systemImage: "doc") { isPickingFile = true }
            }
        case .preview(let preview):
            previewContent(preview)
        case .applying(let completed, let total):
            progressCard(
                total == 0 ? "Adding shows…" : "Restoring listening history (\(completed) of \(total) shows)…",
                cancel: cancelImport
            )
        case .finished(let report):
            reportCard(report)
        }
    }

    @ViewBuilder
    private func previewContent(_ preview: PodcastImportPreview) -> some View {
        SourcesCard {
            Text(preview.candidates.count == 1 ? "1 show in this file" : "\(preview.candidates.count) shows in this file")
                .font(.hearthBody.weight(.semibold))
                .foregroundStyle(hearth.text)
            VStack(alignment: .leading, spacing: 4) {
                previewLine("\(preview.newCount) new, \(preview.alreadySubscribedCount) already subscribed")
                if preview.listeningStateCount > 0 {
                    previewLine("\(preview.listeningStateCount) episodes with listening history")
                }
                if preview.duplicateCount > 0 {
                    previewLine("\(preview.duplicateCount) repeated entries were combined")
                }
                if preview.invalidCount > 0 {
                    previewLine("\(preview.invalidCount) entries have no usable feed address and will be skipped")
                }
            }
            if preview.listeningStateCount > 0 {
                Text("History is matched against each show's current feed, so the selected shows will be loaded. Enve never rewinds newer progress or unfinishes an episode.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("podcast-transfer-preview-summary")

        HStack(spacing: 10) {
            HearthChip(title: "Select all", isSelected: false) { selection = Set(preview.candidates.map(\.key)) }
                .accessibilityIdentifier("podcast-transfer-select-all")
            HearthChip(title: "Select none", isSelected: false) { selection = [] }
                .accessibilityIdentifier("podcast-transfer-select-none")
        }

        SourcesCard {
            ForEach(Array(preview.candidates.enumerated()), id: \.element.key) { index, candidate in
                if index > 0 { Divider().overlay(hearth.hairline) }
                SourcesToggleRow(title: candidate.title, subtitle: subtitle(for: candidate), isOn: binding(for: candidate.key))
                    .accessibilityIdentifier("podcast-transfer-feed-\(index)")
            }
        }

        HStack(spacing: 10) {
            QuietButton(title: "Cancel") { importPhase = .idle }
                .accessibilityIdentifier("podcast-transfer-cancel-preview")
            EmberButton(title: confirmTitle(preview), systemImage: "square.and.arrow.down") { applyImport(preview) }
                .disabled(selection.isEmpty)
                .opacity(selection.isEmpty ? 0.5 : 1)
                .accessibilityIdentifier("podcast-transfer-import-confirm")
        }
    }

    private func previewLine(_ text: String) -> some View {
        Text(text)
            .font(.hearthCaption)
            .foregroundStyle(hearth.textSecondary)
    }

    private func subtitle(for candidate: PodcastImportCandidate) -> String {
        var parts: [String] = []
        if candidate.isAlreadySubscribed {
            parts.append("Already subscribed")
        } else if !candidate.isSubscribedInSource {
            parts.append("Not subscribed in the other app")
        }
        if candidate.playedCount > 0 { parts.append("\(candidate.playedCount) played") }
        if candidate.inProgressCount > 0 { parts.append("\(candidate.inProgressCount) in progress") }
        return parts.isEmpty ? "New show" : parts.joined(separator: " · ")
    }

    private func confirmTitle(_ preview: PodcastImportPreview) -> String {
        let count = preview.candidates.count { selection.contains($0.key) && !$0.isAlreadySubscribed }
        switch count {
        case 0: return "Import history"
        case 1: return "Add 1 show"
        default: return "Add \(count) shows"
        }
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(key) },
            set: { isOn in
                if isOn { selection.insert(key) } else { selection.remove(key) }
            }
        )
    }

    private func reportCard(_ report: PodcastImportReport) -> some View {
        SourcesCard {
            Label(report.wasInterrupted ? "Import stopped" : "Import finished", systemImage: report.wasInterrupted ? "pause.circle" : "checkmark.circle")
                .font(.hearthBody.weight(.semibold))
                .foregroundStyle(report.wasInterrupted ? hearth.statusWarn : hearth.statusOK)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(report.summaryLines, id: \.self) { line in
                    Text(line)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            QuietButton(title: "Done") { importPhase = .idle }
                .accessibilityIdentifier("podcast-transfer-report-done")
        }
        .accessibilityIdentifier("podcast-transfer-report")
    }

    private static func isUserCancellation(_ error: Error) -> Bool {
        (error as? CocoaError)?.code == .userCancelled
    }

    private func read(_ url: URL) {
        importPhase = .reading
        importTask?.cancel()
        importTask = Task {
            let result = await Self.readDocument(at: url)
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let document):
                let preview = PodcastImportPreview(
                    document: document,
                    existingFeedURLs: engine.podcasts.subscriptions.map(\.feedURL)
                )
                selection = preview.defaultSelection
                importPhase = .preview(preview)
            case .failure(let error):
                importPhase = .failed(error.localizedDescription)
            }
        }
    }

    private func applyImport(_ preview: PodcastImportPreview) {
        let chosen = selection
        importPhase = .applying(completed: 0, total: 0)
        importTask = Task {
            let report = await engine.podcasts.migration.importFeeds(from: preview, selection: chosen) { completed, total in
                importPhase = .applying(completed: completed, total: total)
            }
            if engine.podcasts.isProfileActive { podcasts.refreshRSSProgress() }
            importPhase = .finished(report)
        }
    }

    private func cancelImport() {
        importTask?.cancel()
        if case .reading = importPhase { importPhase = .idle }
    }

    private nonisolated static func readDocument(at url: URL) async -> Result<PodcastOPMLDocument, PodcastOPMLError> {
        await Task.detached(priority: .userInitiated) { () -> Result<PodcastOPMLDocument, PodcastOPMLError> in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > PodcastOPMLParser.maximumBytes {
                return .failure(.tooLarge)
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .failure(.unreadable) }
            do throws(PodcastOPMLError) {
                return .success(try PodcastOPMLParser.parse(data))
            } catch {
                return .failure(error)
            }
        }.value
    }

    @ViewBuilder
    private var exportSection: some View {
        let subscriptions = engine.podcasts.subscriptions
        let plan = PodcastExportPlan(subscriptions: subscriptions, episodesByFeedKey: [:], includePrivateFeeds: includePrivateFeeds)
        let hiddenCount = PodcastExportPlan(subscriptions: subscriptions, episodesByFeedKey: [:], includePrivateFeeds: false).exclusions.count

        Overline("Export")
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 8)
        SourcesCard {
            if subscriptions.isEmpty {
                Text("Subscribe to shows to export them. Audiobookshelf podcasts stay on their server and aren't included.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SourcesToggleRow(
                    title: "Include listening history",
                    subtitle: "Played and in-progress episodes, in the extended format Overcast uses",
                    isOn: $includeProgress
                )
                .accessibilityIdentifier("podcast-transfer-include-progress")
                if hiddenCount > 0 {
                    Divider().overlay(hearth.hairline)
                    SourcesToggleRow(
                        title: "Include private feed links",
                        subtitle: "Private feed addresses can work like passwords. Only include them if you trust where the file is going.",
                        isOn: $includePrivateFeeds
                    )
                    .accessibilityIdentifier("podcast-transfer-include-private")
                }
                Divider().overlay(hearth.hairline)
                Text(plan.feeds.count == 1 ? "1 show will be exported." : "\(plan.feeds.count) shows will be exported.")
                    .font(.hearthBody.weight(.medium))
                    .foregroundStyle(hearth.text)
                    .accessibilityIdentifier("podcast-transfer-export-count")
                if !plan.exclusions.isEmpty {
                    exclusionList(plan.exclusions)
                }
                exportControls(isEmpty: plan.feeds.isEmpty)
            }
        }
    }

    private func exclusionList(_ exclusions: [PodcastExportExclusion]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(exclusions.count == 1
                ? "1 show is left out because its link may give access to a private feed:"
                : "\(exclusions.count) shows are left out because their links may give access to private feeds:")
                .font(.hearthCaption)
                .foregroundStyle(hearth.statusWarn)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(exclusions) { exclusion in
                Text("\(exclusion.title) — \(exclusion.concern.explanation.lowercased())")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("podcast-transfer-exclusions")
    }

    @ViewBuilder
    private func exportControls(isEmpty: Bool) -> some View {
        switch exportPhase {
        case .preparing(let completed, let total):
            HStack(spacing: 10) {
                ProgressView().tint(hearth.ember)
                Text(total == 0 ? "Preparing…" : "Gathering history (\(completed) of \(total) shows)…")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                Spacer()
                QuietButton(title: "Cancel") {
                    exportTask?.cancel()
                    exportPhase = .idle
                }
            }
        default:
            EmberButton(title: "Export OPML", systemImage: "square.and.arrow.up") { prepareExport() }
                .disabled(isEmpty)
                .opacity(isEmpty ? 0.5 : 1)
                .accessibilityIdentifier("podcast-transfer-export")
            if case .saved(let result) = exportPhase {
                exportStatus(result)
            } else if case .failed(let message) = exportPhase {
                Text(message)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusError)
            }
        }
    }

    private func exportStatus(_ result: PodcastExportResult) -> some View {
        var text = "Saved \(result.plan.feeds.count) shows"
        if result.plan.episodeStateCount > 0 { text += " and history for \(result.plan.episodeStateCount) episodes" }
        text += "."
        if !result.feedsWithoutProgress.isEmpty {
            text += " History wasn't included for \(result.feedsWithoutProgress.count) shows that couldn't be loaded."
        }
        return Text(text)
            .font(.hearthCaption)
            .foregroundStyle(hearth.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("podcast-transfer-export-status")
    }

    private func prepareExport() {
        exportPhase = .preparing(completed: 0, total: 0)
        let includePrivate = includePrivateFeeds
        let withProgress = includeProgress
        exportTask?.cancel()
        exportTask = Task {
            let result = await engine.podcasts.migration.prepareExport(
                includePrivateFeeds: includePrivate,
                includeProgress: withProgress
            ) { completed, total in
                exportPhase = .preparing(completed: completed, total: total)
            }
            guard !Task.isCancelled, let result else { return }
            exportPhase = .ready(result)
            exportFile = PodcastOPMLFile(data: result.data)
            isExporting = true
        }
    }

    private func progressCard(_ title: String, cancel: @escaping () -> Void) -> some View {
        SourcesCard {
            HStack(spacing: 12) {
                ProgressView().tint(hearth.ember)
                Text(title)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            QuietButton(title: "Stop", systemImage: "xmark", action: cancel)
                .accessibilityIdentifier("podcast-transfer-stop")
        }
    }

    private enum ImportPhase {
        case idle
        case reading
        case failed(String)
        case preview(PodcastImportPreview)
        case applying(completed: Int, total: Int)
        case finished(PodcastImportReport)
    }

    private enum ExportPhase {
        case idle
        case preparing(completed: Int, total: Int)
        case ready(PodcastExportResult)
        case saved(PodcastExportResult)
        case failed(String)
    }
}

nonisolated struct PodcastOPMLFile: FileDocument {
    static var opml: UTType { UTType(filenameExtension: "opml", conformingTo: .xml) ?? .xml }
    // Files providers can report OPML as untyped data; the parser validates its contents.
    static let importTypes: [UTType] = [.data]
    static var readableContentTypes: [UTType] { [opml] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
