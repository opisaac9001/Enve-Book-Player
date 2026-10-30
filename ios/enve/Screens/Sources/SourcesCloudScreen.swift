import Observation
import SwiftUI

struct SourcesCloudScreen: View {
    enum Drive: String, Identifiable {
        case googleDrive, dropbox, icloud

        var id: String { rawValue }

        var title: String {
            switch self {
            case .googleDrive: "Google Drive"
            case .dropbox: "Dropbox"
            case .icloud: "iCloud Drive"
            }
        }

        var glyph: String {
            switch self {
            case .googleDrive: "internaldrive"
            case .dropbox: "shippingbox.fill"
            case .icloud: "icloud"
            }
        }
    }

    let drive: Drive
    let onAdded: () -> Void

    var body: some View {
        switch drive {
        case .googleDrive:
            SourcesCloudDriveBrowser(drive: drive, onAdded: onAdded) { session in
                GoogleDriveProvider(oauthManager: session.oauth, tokenStorage: session.tokenStorage, session: session.networkSession)
            }
        case .dropbox:
            SourcesCloudDriveBrowser(drive: drive, onAdded: onAdded) { session in
                DropboxProvider(oauthManager: session.oauth, tokenStorage: session.tokenStorage, session: session.networkSession)
            }
        case .icloud:
            SourcesFilesScreen(onAdded: onAdded)
        }
    }
}

private struct SourcesCloudDriveBrowser: View {
    let drive: SourcesCloudScreen.Drive
    let onAdded: () -> Void
    let makeProvider: (ProfileSession) -> any BookSourceProvider

    @Environment(\.profileSession) private var profileSession
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var model: SourcesCloudDriveModel?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let model {
                        SourcesCloudDriveContent(title: drive.title, model: model, onAdded: onAdded)
                    } else {
                        ProgressView().tint(hearth.ember)
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .background(HearthBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if (model?.importedTotal ?? 0) > 0 {
                        Button("Done", action: onAdded)
                            .foregroundStyle(hearth.ember)
                    } else {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
            }
        }
        .onAppear {
            guard model == nil else { return }
            let session = profileSession ?? .owner
            let model = SourcesCloudDriveModel(
                title: drive.title,
                provider: makeProvider(session),
                downloader: CloudBookDownloadService(session: session.networkSession)
            )
            self.model = model
            model.start()
        }
        .onDisappear { model?.cancelAll() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            SourcesProviderLogo(assetName: nil, systemName: drive.glyph, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Overline("Cloud drive")
                Text(drive.title)
                    .font(.hearthDisplay(26))
                    .foregroundStyle(hearth.text)
                Text("Download audiobooks and ebooks to this device.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
    }
}

private struct SourcesCloudDriveContent: View {
    let title: String
    @Bindable var model: SourcesCloudDriveModel
    let onAdded: () -> Void

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    var body: some View {
        switch model.phase {
        case .signedOut:
            signInCard
        case .connecting:
            progressCard("Waiting for \(title) sign-in…")
        case .browsing:
            accountCard
            browserCard
            importCard
        }
        if let error = model.errorMessage {
            SourcesErrorText(message: error)
        }
    }

    private var signInCard: some View {
        SourcesCard {
            Overline("Connect")
            Text("Enve requests read-only access to browse \(title). Choose books to download for offline use. Enve cannot change or delete your cloud files.")
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            EmberButton(title: "Sign in to \(title)", systemImage: "person.crop.circle.badge.checkmark", tint: nil) {
                model.connect()
            }
        }
    }

    private var accountCard: some View {
        SourcesCard {
            HStack(spacing: 10) {
                Circle()
                    .fill(hearth.statusOK)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("Connected to \(title)")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                Spacer(minLength: 0)
            }
            QuietButton(title: "Disconnect", systemImage: "xmark.circle") {
                model.disconnect()
            }
            .disabled(model.isImporting)
        }
    }

    private var browserCard: some View {
        SourcesCard {
            HStack {
                Overline(model.isShowingSearchResults ? "Search results" : "Browse")
                Spacer()
                if model.isLoading {
                    ProgressView().tint(hearth.ember)
                }
            }

            searchField

            if !model.isShowingSearchResults {
                breadcrumb
            }

            if !model.isLoading && model.visibleItems.isEmpty {
                Text(model.isShowingSearchResults ? "No matching folders or books." : "No folders or supported books here.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .padding(.vertical, 6)
            }

            ForEach(model.visibleItems) { item in
                SourcesCloudItemRow(item: item, isSelected: model.isSelected(item)) {
                    if item.isFolder {
                        model.open(item)
                    } else {
                        model.toggle(item)
                    }
                }
            }
        }
        .disabled(model.isImporting)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(hearth.textTertiary)
                .accessibilityHidden(true)
            TextField("Search \(title)", text: $model.searchText)
                .font(.hearthBody)
                .foregroundStyle(hearth.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { model.search() }
            if !model.searchText.isEmpty {
                Button {
                    model.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(hearth.textTertiary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Clear search")
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
        .onChange(of: model.searchText) { _, value in
            if value.isEmpty { model.clearSearch() }
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(model.folderStack.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.hearthUI(10, weight: .semibold))
                            .foregroundStyle(hearth.textTertiary)
                            .accessibilityHidden(true)
                    }
                    let isCurrent = index == model.folderStack.indices.last
                    Button(crumb.name) {
                        model.goToCrumb(at: index)
                    }
                    .font(.hearthCaption.weight(.medium))
                    .foregroundStyle(isCurrent ? hearth.text : hearth.ember)
                    .frame(minHeight: 44)
                    .disabled(isCurrent)
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Current \(title) folder")
    }

    @ViewBuilder
    private var importCard: some View {
        SourcesCard {
            switch model.importState {
            case .idle:
                selectionContent
            case let .downloading(completed, total):
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: Double(completed), total: Double(max(total, 1)))
                        .tint(hearth.ember)
                    Text("Downloading \(completed) of \(total) file\(total == 1 ? "" : "s")…")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
                .accessibilityElement(children: .combine)
            case .importing:
                HStack(spacing: 10) {
                    ProgressView().tint(hearth.ember)
                    Text("Adding books to your library…")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
                .accessibilityElement(children: .combine)
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
                Text("Downloaded to this device and available offline.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                EmberButton(title: "Done", systemImage: "checkmark", tint: nil, action: onAdded)
                QuietButton(title: "Import more", systemImage: "plus") {
                    model.resetImport()
                }
            }
        }
    }

    @ViewBuilder
    private var selectionContent: some View {
        let count = model.selection.count
        Overline("Import")
        if count == 0 {
            Text("Select audiobook or ebook files to download. Tap a folder to open it; folders can't be imported as a whole.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(selectionSummary(count: count))
                .font(.hearthBody.weight(.medium))
                .foregroundStyle(hearth.text)
            QuietButton(title: "Clear selection", systemImage: "xmark.circle") {
                model.clearSelection()
            }
        }
        SourcesToggleRow(
            title: "Combine selected audio tracks into one book",
            subtitle: "Tracks from the same folder become one audiobook. When off, each file becomes its own book.",
            isOn: $model.combinesAudioTracks
        )
        EmberButton(
            title: count == 0 ? "Download and import" : "Download and import \(count)",
            systemImage: "arrow.down.circle",
            tint: nil
        ) {
            model.importSelection(using: engine)
        }
        .disabled(count == 0)
    }

    private func selectionSummary(count: Int) -> String {
        let files = "\(count) file\(count == 1 ? "" : "s") selected"
        guard let size = model.selectionSize else { return files }
        return "\(files) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }

    private func progressCard(_ message: String) -> some View {
        SourcesCard {
            HStack(spacing: 10) {
                ProgressView().tint(hearth.ember)
                Text(message)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct SourcesCloudItemRow: View {
    let item: RemoteItem
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: glyph)
                    .font(.hearthUI(18))
                    .foregroundStyle(item.isFolder || isSelected ? hearth.ember : hearth.textSecondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                if item.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.hearthUI(12, weight: .semibold))
                        .foregroundStyle(hearth.textTertiary)
                } else {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.hearthUI(20))
                        .foregroundStyle(isSelected ? hearth.ember : hearth.textTertiary)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(item.isFolder ? "\(item.name), folder" : item.name)
        .accessibilityValue(detail ?? "")
        .accessibilityHint(item.isFolder ? "Opens the folder" : (isSelected ? "Removes from import" : "Adds to import"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var glyph: String {
        if item.isFolder { return "folder.fill" }
        return AudiobookFormat.from(fileExtension: (item.name as NSString).pathExtension.lowercased()) != nil ? "waveform" : "book.closed"
    }

    private var detail: String? {
        guard !item.isFolder, let size = item.size else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

@MainActor
@Observable
final class SourcesCloudDriveModel {
    enum Phase: Equatable {
        case signedOut
        case connecting
        case browsing
    }

    enum ImportState: Equatable {
        case idle
        case downloading(completed: Int, total: Int)
        case importing
        case finished(count: Int)
    }

    struct Crumb: Equatable {
        let id: String?
        let name: String
    }

    private(set) var phase: Phase = .signedOut
    private(set) var folderStack: [Crumb] = []
    private(set) var items: [RemoteItem] = []
    private(set) var searchResults: [RemoteItem] = []
    private(set) var isShowingSearchResults = false
    private(set) var isLoading = false
    private(set) var selection: [RemoteItem] = []
    private(set) var importState: ImportState = .idle
    private(set) var importedTotal = 0
    var errorMessage: String?
    var searchText = ""
    var combinesAudioTracks = false

    @ObservationIgnored private let title: String
    @ObservationIgnored private let provider: any BookSourceProvider
    @ObservationIgnored private let downloader: CloudBookDownloadService
    @ObservationIgnored private var authTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var listRequest = 0

    init(title: String, provider: any BookSourceProvider, downloader: CloudBookDownloadService) {
        self.title = title
        self.provider = provider
        self.downloader = downloader
    }

    var visibleItems: [RemoteItem] {
        isShowingSearchResults ? searchResults : items
    }

    var isImporting: Bool {
        switch importState {
        case .downloading, .importing: true
        case .idle, .finished: false
        }
    }

    var selectionSize: Int64? {
        let sizes = selection.compactMap(\.size)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    private var currentFolderID: String? {
        folderStack.last?.id ?? nil
    }

    func start() {
        switch provider.authenticationState {
        case .authenticated:
            enterBrowsing()
        case .tokenExpired:
            phase = .connecting
            authTask = Task {
                do {
                    try await provider.refreshAuthentication()
                    try Task.checkCancellation()
                    enterBrowsing()
                } catch {
                    guard !Task.isCancelled else { return }
                    returnToSignIn(message: "Your \(title) sign-in expired. Sign in again.")
                }
                authTask = nil
            }
        case let .authenticationFailed(message):
            errorMessage = message
        case .notAuthenticated, .authenticating:
            break
        }
    }

    func connect() {
        guard phase == .signedOut, authTask == nil else { return }
        phase = .connecting
        errorMessage = nil
        authTask = Task {
            do {
                try await provider.authenticate()
                try Task.checkCancellation()
                enterBrowsing()
            } catch {
                phase = .signedOut
                if !isCancellation(error) { errorMessage = error.localizedDescription }
            }
            authTask = nil
        }
    }

    func disconnect() {
        guard !isImporting, authTask == nil else { return }
        authTask = Task {
            do {
                try await provider.signOut()
                returnToSignIn(message: nil)
            } catch {
                errorMessage = error.localizedDescription
            }
            authTask = nil
        }
    }

    func open(_ item: RemoteItem) {
        guard item.isFolder else { return }
        let crumb = Crumb(id: item.id, name: item.name)
        if isShowingSearchResults {
            isShowingSearchResults = false
            searchResults = []
            searchText = ""
            folderStack = [folderStack.first ?? Crumb(id: nil, name: title), crumb]
        } else {
            folderStack.append(crumb)
        }
        load(item.id)
    }

    func goToCrumb(at index: Int) {
        guard folderStack.indices.contains(index), index < folderStack.count - 1 else { return }
        folderStack.removeSubrange((index + 1)...)
        load(currentFolderID)
    }

    func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .browsing, !query.isEmpty else { return }
        isShowingSearchResults = true
        searchResults = []
        errorMessage = nil
        runListing({ [provider] in try await provider.search(query) }) { [weak self] in
            self?.searchResults = $0
        }
    }

    func clearSearch() {
        searchText = ""
        guard isShowingSearchResults else { return }
        isShowingSearchResults = false
        searchResults = []
        load(currentFolderID)
    }

    func isSelected(_ item: RemoteItem) -> Bool {
        selection.contains { $0.id == item.id }
    }

    func toggle(_ item: RemoteItem) {
        guard item.isSupportedBookFile, !isImporting else { return }
        if case .finished = importState { importState = .idle }
        if let index = selection.firstIndex(where: { $0.id == item.id }) {
            selection.remove(at: index)
        } else {
            selection.append(item)
        }
    }

    func clearSelection() {
        selection = []
    }

    func resetImport() {
        importState = .idle
    }

    func importSelection(using engine: EnveEngine) {
        guard importTask == nil, !selection.isEmpty else { return }
        let items = selection
        let mode: SourcesFilesImportMode = combinesAudioTracks ? .groupByFolder : .splitSelectedBooks
        errorMessage = nil
        importState = .downloading(completed: 0, total: items.count)
        importTask = Task { [self] in
            defer { importTask = nil }
            do {
                let staging = try await withRefreshedAuthentication {
                    try await downloader.stage(items: items, provider: provider, preserveFolderGrouping: combinesAudioTracks) { [weak self] completed, total in
                        self?.importState = .downloading(completed: completed, total: total)
                    }
                }
                defer { staging.remove() }
                importState = .importing
                let count = try await engine.sources.importFiles(urls: staging.urls, mode: mode)
                guard count > 0 else {
                    importState = .idle
                    errorMessage = "None of the selected files could be added as books."
                    return
                }
                selection = []
                importedTotal += count
                importState = .finished(count: count)
                PlatformHaptics.notification(.success)
            } catch {
                importState = .idle
                if !isCancellation(error) { errorMessage = error.localizedDescription }
            }
        }
    }

    func cancelAll() {
        authTask?.cancel()
        listTask?.cancel()
        importTask?.cancel()
        authTask = nil
        listTask = nil
        importTask = nil
        listRequest += 1
        isLoading = false
    }

    private func enterBrowsing() {
        phase = .browsing
        errorMessage = nil
        folderStack = [Crumb(id: nil, name: title)]
        load(nil)
    }

    private func load(_ folderID: String?) {
        errorMessage = nil
        runListing({ [provider] in
            if let folderID {
                return try await provider.listFolder(folderID)
            }
            return try await provider.listRoot()
        }) { [weak self] in
            self?.items = $0
        }
    }

    private func runListing(
        _ request: @escaping () async throws -> [RemoteItem],
        apply: @escaping ([RemoteItem]) -> Void
    ) {
        listTask?.cancel()
        listRequest += 1
        let requestID = listRequest
        isLoading = true
        listTask = Task {
            do {
                let result = try await withRefreshedAuthentication(request)
                guard requestID == listRequest else { return }
                apply(Self.browsable(result))
            } catch {
                guard requestID == listRequest else { return }
                handleListingError(error)
            }
            if requestID == listRequest { isLoading = false }
        }
    }

    private func withRefreshedAuthentication<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard provider.authenticationState == .tokenExpired else { throw error }
            try await provider.refreshAuthentication()
            return try await operation()
        }
    }

    private func handleListingError(_ error: Error) {
        guard !isCancellation(error) else { return }
        if provider.authenticationState.isAuthenticated {
            errorMessage = error.localizedDescription
        } else {
            returnToSignIn(message: "Your \(title) sign-in expired. Sign in again.")
        }
    }

    private func returnToSignIn(message: String?) {
        listTask?.cancel()
        listTask = nil
        listRequest += 1
        isLoading = false
        items = []
        searchResults = []
        isShowingSearchResults = false
        searchText = ""
        folderStack = []
        selection = []
        importState = .idle
        phase = .signedOut
        errorMessage = message
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        if case .userCancelled? = error as? OAuthError { return true }
        return false
    }

    private static func browsable(_ items: [RemoteItem]) -> [RemoteItem] {
        items
            .filter { $0.isFolder || $0.isSupportedBookFile }
            .sorted {
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
