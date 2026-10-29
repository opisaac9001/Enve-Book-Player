#if !os(tvOS)
import Combine
import Observation
import SwiftUI
import WebKit

struct SourcesWebImportScreen: View {
    let onAdded: () -> Void

    @State private var model: SourcesWebImportModel?

    var body: some View {
        Group {
            if let model {
                SourcesWebImportForm(model: model, onAdded: onAdded)
            } else {
                HearthBackground()
            }
        }
        .onAppear {
            guard model == nil else { return }
            model = SourcesWebImportModel()
        }
        .onDisappear { model?.cancelAll() }
    }
}

private struct SourcesWebImportForm: View {
    @Bindable var model: SourcesWebImportModel
    let onAdded: () -> Void

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isURLFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        linkCard
                        if model.phase == .previewing {
                            readingCard
                        }
                        if let preview = model.preview {
                            previewCard(preview)
                                .id("web-preview")
                        }
                        if let error = model.errorMessage {
                            VStack(alignment: .leading, spacing: 6) {
                                SourcesErrorText(message: error)
                                Text("If the site asks you to sign in or verify access, open it in the browser, then import the page you’re viewing.")
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id("web-error")
                        }
                    }
                    .padding(24)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("web-import-screen")
                .scrollDismissesKeyboard(.interactively)
                .background(HearthBackground())
                .onChange(of: model.preview?.sourceURL) { _, url in
                    guard url != nil else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        proxy.scrollTo("web-preview", anchor: .top)
                    }
                }
                .onChange(of: model.errorMessage) { _, error in
                    guard error != nil else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        proxy.scrollTo("web-error", anchor: .bottom)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .finished = model.phase {
                        Button("Done", action: onAdded)
                            .foregroundStyle(hearth.ember)
                    } else if model.phase != .adding {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.phase == .adding)
        .sheet(isPresented: $model.isBrowserPresented) {
            SourcesWebImportBrowser(service: model.service) { preview in
                model.accept(preview)
            }
            .enveEnvironment()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                SourcesProviderLogo(assetName: nil, systemName: "link", size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Overline("From the web")
                    Text("Web link")
                        .font(.hearthDisplay(26))
                        .foregroundStyle(hearth.text)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            Text("Save articles and web stories to read or listen offline.")
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var linkCard: some View {
        SourcesCard {
            Overline("Link")
            urlField
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    pasteButton
                    browserButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    pasteButton
                    browserButton
                }
            }
            EmberButton(title: "Preview", systemImage: "doc.text.magnifyingglass", tint: nil) {
                isURLFocused = false
                model.loadPreview()
            }
            .disabled(!model.canPreview)
            .accessibilityHint("Checks the page and shows what will be imported")
            .accessibilityIdentifier("web-import-preview")
        }
    }

    private var urlField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(hearth.textTertiary)
                .accessibilityHidden(true)
            TextField("https://", text: $model.urlText)
                .font(.hearthBody)
                .foregroundStyle(hearth.text)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($isURLFocused)
                .onSubmit { isURLFocused = false; model.loadPreview() }
                .accessibilityLabel("Web page link")
                .accessibilityIdentifier("web-import-url")
            if !model.urlText.isEmpty {
                Button {
                    model.urlText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(hearth.textTertiary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Clear link")
            }
        }
        .padding(.leading, 14)
        .frame(minHeight: 44)
        .background {
            HearthChromeBackground(
                shape: .rounded(12),
                fill: hearth.bg,
                stroke: hearth.hairline,
                tint: hearth.bgElevated
            )
        }
        .disabled(model.isImporting)
    }

    private var pasteButton: some View {
        PasteButton(payloadType: String.self) { @Sendable [model] strings in
            guard let text = strings.first else { return }
            Task { @MainActor in model.paste(text) }
        }
        .labelStyle(.titleAndIcon)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(hearth.ember)
        .disabled(model.isImporting)
    }

    private var browserButton: some View {
        QuietButton(title: "Open in browser", systemImage: "safari") {
            isURLFocused = false
            model.openBrowser()
        }
        .disabled(!model.canPreview)
        .accessibilityHint("Use this when a site blocks Enve or needs you to sign in")
        .accessibilityIdentifier("web-import-browser")
    }

    private var readingCard: some View {
        SourcesCard {
            HStack(spacing: 10) {
                ProgressView().tint(hearth.ember)
                Text("Reading the page…")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
            }
            .accessibilityElement(children: .combine)
            QuietButton(title: "Stop", systemImage: "xmark") {
                model.stop()
            }
        }
    }

    private func previewCard(_ preview: WebStoryPreview) -> some View {
        SourcesCard {
            VStack(alignment: .leading, spacing: 6) {
                Overline(preview.siteName)
                Text(preview.title)
                    .font(.hearthDisplay(22))
                    .foregroundStyle(hearth.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let author = preview.author {
                    Text("by \(author)")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            if !preview.excerpt.isEmpty {
                Text(preview.excerpt)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(4)
            }
            if let details = details(for: preview) {
                Text(details)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
            if !preview.isDirectFile {
                Text("Saves readable text, formatting, and chapter navigation for offline reading.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
            if !preview.isDirectFile && preview.chapters.count > 1 {
                scopePicker(preview)
            }
            importArea
        }
    }

    private func details(for preview: WebStoryPreview) -> String? {
        var parts: [String] = []
        if preview.wordCount > 0, !preview.isStoryIndex {
            let location = preview.chapters.count > 1 ? " in this chapter" : ""
            parts.append("\(preview.wordCount.formatted()) words\(location)")
        }
        if preview.isDirectFile {
            parts.append("Book file")
        } else if preview.chapters.count > 1 {
            parts.append("\(preview.chapters.count) chapters found")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func scopePicker(_ preview: WebStoryPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Overline("What to import")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { scopeChips }
                VStack(alignment: .leading, spacing: 8) { scopeChips }
            }
            if model.scope != .whole {
                Text("Starts at “\(preview.chapters[preview.currentChapterIndex].title)”")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(model.phase != .idle)
    }

    private var scopeChips: some View {
        ForEach(model.availableScopes) { scope in
            let count = model.chapters(for: scope).count
            HearthChip(title: scope.title, isSelected: model.scope == scope) {
                model.scope = scope
            }
            .accessibilityLabel("\(scope.title), \(count) chapter\(count == 1 ? "" : "s")")
        }
    }

    @ViewBuilder
    private var importArea: some View {
        switch model.phase {
        case .idle, .previewing:
            EmberButton(title: model.importTitle, systemImage: "arrow.down.circle", tint: nil) {
                model.importSelection(using: engine)
            }
            .disabled(model.phase != .idle)
            .accessibilityHint("Saves to your library")
            .accessibilityIdentifier("web-import-confirm")
        case .staging:
            stagingProgress
            QuietButton(title: "Stop", systemImage: "xmark") {
                model.stop()
            }
        case .adding:
            HStack(spacing: 10) {
                ProgressView().tint(hearth.ember)
                Text("Adding to your library…")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("web-import-progress")
        case let .finished(count):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(hearth.statusOK)
                    .accessibilityHidden(true)
                Text("\(count) book\(count == 1 ? "" : "s") added to your library.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
            }
            .accessibilityElement(children: .combine)
            Text("Open it from your library to read, or listen with text-to-speech.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            EmberButton(title: "Done", systemImage: "checkmark", tint: nil, action: onAdded)
            QuietButton(title: "Import another", systemImage: "plus") {
                model.reset()
            }
        }
    }

    private var stagingProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress = model.service.progress {
                ProgressView(value: progress.fraction)
                    .tint(hearth.ember)
                Text("\(progress.completedChapters) of \(progress.totalChapters) chapter\(progress.totalChapters == 1 ? "" : "s") saved")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                if !progress.chapterTitle.isEmpty {
                    Text(progress.chapterTitle)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                        .lineLimit(2)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().tint(hearth.ember)
                    Text("Getting ready…")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("web-import-progress")
    }
}

private struct SourcesWebImportBrowser: View {
    let service: WebStoryImportService
    let onPreview: (WebStoryPreview) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var isReading = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var canGoBack = false
    @State private var canGoForward = false

    var body: some View {
        NavigationStack {
            SourcesWebImportWebView(webView: service.webView)
                .safeAreaInset(edge: .bottom, spacing: 0) { controls }
                .navigationTitle(service.currentURL?.host() ?? "Browser")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(hearth.ember)
                    }
                }
        }
        .onReceive(service.webView.publisher(for: \.canGoBack)) { canGoBack = $0 }
        .onReceive(service.webView.publisher(for: \.canGoForward)) { canGoForward = $0 }
        .onDisappear { task?.cancel() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage {
                SourcesErrorText(message: errorMessage)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    navigationButtons
                    Spacer(minLength: 8)
                    importButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) { navigationButtons }
                    importButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            hearth.bgElevated
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(hearth.hairline)
                        .frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private var navigationButtons: some View {
        let webView = service.webView
        GlyphButton(systemImage: "chevron.backward", label: "Back") { webView.goBack() }
            .disabled(!canGoBack)
            .accessibilityIdentifier("web-import-browser-back")
        GlyphButton(systemImage: "chevron.forward", label: "Forward") { webView.goForward() }
            .disabled(!canGoForward)
            .accessibilityIdentifier("web-import-browser-forward")
        GlyphButton(systemImage: "arrow.clockwise", label: "Reload") { webView.reload() }
    }

    private var importButton: some View {
        HStack(spacing: 10) {
            if isReading {
                ProgressView()
                    .tint(hearth.ember)
                    .accessibilityLabel("Reading the page")
            }
            EmberButton(title: "Import this page", systemImage: "arrow.down.doc", tint: nil) {
                previewPage()
            }
            .disabled(isReading)
            .accessibilityHint("Shows a preview of the page you’re viewing before saving")
            .accessibilityIdentifier("web-import-browser-page")
        }
    }

    private func previewPage() {
        task?.cancel()
        errorMessage = nil
        isReading = true
        task = Task {
            do {
                let preview = try await service.previewCurrentPage()
                try Task.checkCancellation()
                onPreview(preview)
                dismiss()
            } catch {
                isReading = false
                if !SourcesWebImportModel.isCancellation(error) {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct SourcesWebImportWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context _: Context) -> WKWebView { webView }

    func updateUIView(_: WKWebView, context _: Context) {}
}

@MainActor
@Observable
final class SourcesWebImportModel {
    enum Phase: Equatable {
        case idle
        case previewing
        case staging
        case adding
        case finished(count: Int)
    }

    enum Scope: CaseIterable, Identifiable {
        case chapter, fromHere, whole

        var id: Self { self }

        var title: String {
            switch self {
            case .chapter: "This chapter"
            case .fromHere: "From here"
            case .whole: "Whole story"
            }
        }
    }

    let service = WebStoryImportService()
    private(set) var phase: Phase = .idle
    private(set) var preview: WebStoryPreview?
    var scope: Scope = .whole
    var errorMessage: String?
    var isBrowserPresented = false

    var urlText = "" {
        didSet {
            guard urlText != oldValue else { return }
            if phase == .previewing { stop() }
            if case .finished = phase { phase = .idle }
            if let preview, preview.sourceURL.absoluteString != urlText { self.preview = nil }
            errorMessage = nil
        }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var request = 0

    var isImporting: Bool {
        phase == .staging || phase == .adding
    }

    var canPreview: Bool {
        !isImporting && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var availableScopes: [Scope] {
        guard let preview else { return [] }
        return preview.currentChapterIndex > 0 ? Scope.allCases : [.chapter, .whole]
    }

    var importTitle: String {
        guard let preview else { return "Import" }
        if preview.isDirectFile { return "Import book" }
        guard preview.chapters.count > 1 else { return "Import page" }
        let count = chapters(for: scope).count
        return "Import \(count) chapter\(count == 1 ? "" : "s")"
    }

    func chapters(for scope: Scope) -> Range<Int> {
        guard let preview else { return 0..<0 }
        let count = preview.chapters.count
        guard count > 1 else { return 0..<count }
        let current = preview.currentChapterIndex
        switch scope {
        case .chapter: return current..<(current + 1)
        case .fromHere: return current..<count
        case .whole: return 0..<count
        }
    }

    func paste(_ text: String) {
        urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func loadPreview() {
        guard canPreview else { return }
        let url: URL
        do {
            url = try WebStoryImportService.validatedURL(from: urlText)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let id = begin(.previewing)
        preview = nil
        task = Task {
            do {
                let preview = try await service.preview(url: url)
                guard id == request else { return }
                show(preview)
            } catch {
                finish(id, with: error)
            }
        }
    }

    func openBrowser() {
        guard canPreview else { return }
        do {
            let url = try WebStoryImportService.validatedURL(from: urlText)
            begin(.idle)
            service.openInBrowser(url)
            isBrowserPresented = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func accept(_ preview: WebStoryPreview) {
        begin(.idle)
        urlText = preview.sourceURL.absoluteString
        show(preview)
    }

    func importSelection(using engine: EnveEngine) {
        guard let preview, phase == .idle else { return }
        let chapters = chapters(for: scope)
        let id = begin(.staging)
        task = Task {
            do {
                let staging = try await service.stage(preview: preview, chapters: chapters)
                defer { staging.remove() }
                guard id == request else { return }
                phase = .adding
                let count = try await engine.sources.importFiles(urls: [staging.url], mode: .groupByFolder)
                guard id == request else { return }
                task = nil
                guard count > 0 else {
                    phase = .idle
                    errorMessage = "Enve couldn’t turn this page into a book."
                    return
                }
                phase = .finished(count: count)
                PlatformHaptics.notification(.success)
            } catch {
                finish(id, with: error)
            }
        }
    }

    func stop() {
        cancelAll()
        phase = .idle
    }

    func reset() {
        cancelAll()
        preview = nil
        phase = .idle
        urlText = ""
    }

    func cancelAll() {
        task?.cancel()
        task = nil
        request += 1
        service.cancel()
    }

    @discardableResult
    private func begin(_ phase: Phase) -> Int {
        cancelAll()
        self.phase = phase
        errorMessage = nil
        return request
    }

    private func show(_ preview: WebStoryPreview) {
        self.preview = preview
        scope = preview.isStoryIndex ? .whole : .chapter
        phase = .idle
        task = nil
    }

    private func finish(_ id: Int, with error: Error) {
        guard id == request else { return }
        task = nil
        phase = .idle
        if !Self.isCancellation(error) {
            errorMessage = error.localizedDescription
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return false
    }
}
#endif
