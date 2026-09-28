import Observation
import SwiftUI

struct SourcesOneDriveScreen: View {
    let onAdded: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var model = SourcesOneDriveModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    switch model.phase {
                    case .signedOut:
                        signInCard
                    case .connecting:
                        progressCard("Opening Microsoft sign-in…")
                    case .browsing:
                        accountCard
                        browserCard
                        selectionCard
                    case .saving:
                        progressCard("Adding your OneDrive libraries…")
                    }
                    if let error = model.errorMessage {
                        SourcesErrorText(message: error)
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .background(HearthBackground())
            .navigationTitle("OneDrive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            .searchable(
                text: $model.searchText,
                isPresented: $model.isSearching,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search OneDrive"
            )
            .onSubmit(of: .search) {
                Task { await model.search() }
            }
            .onChange(of: model.searchText) { _, value in
                if value.isEmpty { model.clearSearch() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            SourcesProviderLogo(assetName: nil, systemName: "cloud.fill", size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Overline("Cloud drive")
                Text("Microsoft OneDrive")
                    .font(.hearthDisplay(26))
                    .foregroundStyle(hearth.text)
                Text("Stream, download, and refresh your books.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
    }

    private var signInCard: some View {
        SourcesCard {
            Overline("Connect")
            Text("Enve requests read-only access to your OneDrive files. It cannot upload, change, or delete them.")
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
            EmberButton(
                title: "Sign in with Microsoft",
                systemImage: "person.crop.circle.badge.checkmark",
                tint: nil
            ) {
                Task { await model.connect() }
            }
        }
    }

    private var accountCard: some View {
        SourcesCard {
            Overline("Connected account")
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.hearthUI(30))
                    .foregroundStyle(hearth.ember)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.account?.displayName ?? "Microsoft account")
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                    Text(model.account?.driveName ?? "OneDrive")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
            }
        }
    }

    private var browserCard: some View {
        SourcesCard {
            HStack {
                Overline(model.isShowingSearchResults ? "Search results" : "Choose folders")
                Spacer()
                if model.isLoading {
                    ProgressView().tint(hearth.ember)
                }
            }

            if !model.isShowingSearchResults {
                breadcrumb
                QuietButton(
                    title: model.isCurrentFolderSelected ? "Remove this folder" : "Use this folder",
                    systemImage: model.isCurrentFolderSelected ? "minus.circle" : "plus.circle"
                ) {
                    model.toggleCurrentFolder()
                }
                .disabled(model.currentFolder == nil)
            }

            if !model.isLoading && model.visibleItems.isEmpty {
                Text(model.isShowingSearchResults ? "No matching book folders." : "This folder has no supported books or subfolders.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .padding(.vertical, 6)
            }

            ForEach(model.visibleItems) { item in
                OneDriveItemRow(
                    item: item,
                    isSelected: model.isSelected(item.id),
                    onOpen: { Task { await model.open(item) } },
                    onToggle: { model.toggle(item) }
                )
            }
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(model.folderStack.enumerated()), id: \.element.id) { index, folder in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.hearthUI(10, weight: .semibold))
                            .foregroundStyle(hearth.textTertiary)
                    }
                    Button(folder.name) {
                        Task { await model.goToFolder(at: index) }
                    }
                    .font(.hearthCaption.weight(.medium))
                    .foregroundStyle(index == model.folderStack.indices.last ? hearth.text : hearth.ember)
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Current OneDrive folder")
    }

    private var selectionCard: some View {
        SourcesCard {
            Overline("Selected libraries")
            if model.selectedFolders.isEmpty {
                Text("Choose at least one folder. Each selected folder becomes an Enve library.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            } else {
                ForEach(model.selectedFolders) { folder in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(hearth.ember)
                        Text(folder.name)
                            .font(.hearthBody)
                            .foregroundStyle(hearth.text)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            model.toggle(folder)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(hearth.textTertiary)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Remove \(folder.name)")
                    }
                }
            }

            EmberButton(title: "Add OneDrive", systemImage: "checkmark", tint: nil) {
                Task {
                    if await model.save(into: appState) {
                        onAdded()
                    }
                }
            }
            .disabled(model.selectedFolders.isEmpty || model.phase == .saving)
        }
    }

    private func progressCard(_ message: String) -> some View {
        SourcesCard {
            HStack(spacing: 10) {
                ProgressView().tint(hearth.ember)
                Text(message)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
    }
}

private struct OneDriveItemRow: View {
    let item: OneDriveBrowserItem
    let isSelected: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 10) {
            Button(action: item.isFolder ? onOpen : {}) {
                HStack(spacing: 10) {
                    Image(systemName: item.isFolder ? "folder.fill" : "book.closed")
                        .foregroundStyle(item.isFolder ? hearth.ember : hearth.textSecondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.hearthBody)
                            .foregroundStyle(hearth.text)
                            .lineLimit(2)
                        if let size = item.size, !item.isFolder {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textTertiary)
                        }
                    }
                    Spacer()
                    if item.isFolder {
                        Image(systemName: "chevron.right")
                            .font(.hearthUI(12, weight: .semibold))
                            .foregroundStyle(hearth.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.isFolder)

            if item.isFolder {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.hearthUI(20))
                        .foregroundStyle(isSelected ? hearth.statusOK : hearth.textTertiary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isSelected ? "Remove \(item.name)" : "Select \(item.name)")
            }
        }
    }
}

@MainActor
@Observable
final class SourcesOneDriveModel {
    enum Phase: Equatable {
        case signedOut
        case connecting
        case browsing
        case saving
    }

    private(set) var phase: Phase = .signedOut
    private(set) var account: OneDriveAccount?
    private(set) var folderStack: [OneDriveBrowserItem] = []
    private(set) var items: [OneDriveBrowserItem] = []
    private(set) var searchResults: [OneDriveBrowserItem] = []
    private(set) var selectedById: [String: OneDriveBrowserItem] = [:]
    private(set) var isLoading = false
    var errorMessage: String?
    var searchText = ""
    var isSearching = false

    private let connectionId = UUID()
    private let provider: OneDriveProvider

    init() {
        provider = OneDriveProvider(
            connection: ServerConnection(
                id: connectionId,
                name: "OneDrive",
                url: "https://graph.microsoft.com/v1.0",
                type: .oneDrive,
                isConnected: false,
                authMode: .sso
            )
        )
    }

    var currentFolder: OneDriveBrowserItem? { folderStack.last }
    var visibleItems: [OneDriveBrowserItem] { isShowingSearchResults ? searchResults : items }
    var isShowingSearchResults: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var selectedFolders: [OneDriveBrowserItem] {
        selectedById.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    var isCurrentFolderSelected: Bool {
        currentFolder.map { selectedById[$0.id] != nil } ?? false
    }

    func connect() async {
        phase = .connecting
        errorMessage = nil
        do {
            account = try await provider.authenticate()
            let root = try await provider.rootBrowserItem()
            folderStack = [root]
            phase = .browsing
            await loadCurrentFolder()
        } catch OAuthError.userCancelled {
            phase = .signedOut
        } catch {
            phase = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    func open(_ item: OneDriveBrowserItem) async {
        guard item.isFolder else { return }
        folderStack.append(item)
        searchText = ""
        await loadCurrentFolder()
    }

    func goToFolder(at index: Int) async {
        guard folderStack.indices.contains(index) else { return }
        folderStack.removeSubrange(folderStack.index(after: index)..<folderStack.endIndex)
        searchText = ""
        await loadCurrentFolder()
    }

    func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            searchResults = try await provider.search(query)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func clearSearch() {
        searchResults = []
    }

    func isSelected(_ id: String) -> Bool { selectedById[id] != nil }

    func toggle(_ item: OneDriveBrowserItem) {
        guard item.isFolder else { return }
        if selectedById.removeValue(forKey: item.id) == nil {
            selectedById[item.id] = item
        }
    }

    func toggleCurrentFolder() {
        guard let currentFolder else { return }
        toggle(currentFolder)
    }

    func save(into appState: AppState) async -> Bool {
        guard !selectedById.isEmpty else { return false }
        phase = .saving
        errorMessage = nil

        var connection = provider.connection
        if let displayName = account?.displayName {
            connection.name = "OneDrive — \(displayName)"
        } else {
            connection.name = "OneDrive"
        }
        connection.userId = account?.driveId
        connection.selectedLibraryIds = Set(selectedById.keys)
        connection.isConnected = true
        connection.lastVerified = Date()
        connection.authMode = .sso
        provider.connection = connection

        let resolved = SourcesFinalizer.resolvedConnection(connection, in: appState)
        do {
            try OneDriveProvider.moveCredentials(from: connection.id, to: resolved.id)
        } catch {
            phase = .browsing
            errorMessage = error.localizedDescription
            return false
        }
        let stored = SourcesFinalizer.upsert(resolved, into: appState)
        await SourcesFinalizer.importAndSync(providerId: stored.id)
        PlatformHaptics.notification(.success)
        return true
    }

    private func loadCurrentFolder() async {
        guard let currentFolder else { return }
        isLoading = true
        errorMessage = nil
        do {
            items = try await provider.listBrowserItems(folderId: currentFolder.id)
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct SourcesOneDriveLibraryPicker: View {
    let onSave: (Set<String>) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var model: SourcesOneDriveLibraryPickerModel

    init(connection: ServerConnection, onSave: @escaping (Set<String>) -> Void) {
        self.onSave = onSave
        _model = State(initialValue: SourcesOneDriveLibraryPickerModel(connection: connection))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SourcesCard {
                        HStack {
                            Overline("OneDrive folders")
                            Spacer()
                            if model.isLoading { ProgressView().tint(hearth.ember) }
                        }

                        if !model.folderStack.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 6) {
                                    ForEach(Array(model.folderStack.enumerated()), id: \.element.id) { index, folder in
                                        if index > 0 {
                                            Image(systemName: "chevron.right")
                                                .font(.hearthUI(10, weight: .semibold))
                                                .foregroundStyle(hearth.textTertiary)
                                        }
                                        Button(folder.name) {
                                            Task { await model.goToFolder(at: index) }
                                        }
                                        .font(.hearthCaption.weight(.medium))
                                        .foregroundStyle(index == model.folderStack.indices.last ? hearth.text : hearth.ember)
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                        }

                        if let current = model.folderStack.last {
                            QuietButton(
                                title: model.isSelected(current.id) ? "Remove this folder" : "Use this folder",
                                systemImage: model.isSelected(current.id) ? "minus.circle" : "plus.circle"
                            ) {
                                model.toggle(current)
                            }
                        }

                        ForEach(model.items) { item in
                            OneDriveItemRow(
                                item: item,
                                isSelected: model.isSelected(item.id),
                                onOpen: { Task { await model.open(item) } },
                                onToggle: { model.toggle(item) }
                            )
                        }

                        if !model.isLoading && model.items.isEmpty {
                            Text("This folder has no supported books or subfolders.")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                    }

                    if let error = model.errorMessage {
                        SourcesErrorText(message: error)
                    }
                }
                .padding(24)
            }
            .background(HearthBackground())
            .navigationTitle("Choose libraries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(model.selectedIds)
                        dismiss()
                    }
                    .disabled(model.selectedIds.isEmpty)
                }
            }
            .task { await model.load() }
        }
    }
}

@MainActor
@Observable
private final class SourcesOneDriveLibraryPickerModel {
    private(set) var folderStack: [OneDriveBrowserItem] = []
    private(set) var items: [OneDriveBrowserItem] = []
    private(set) var selectedIds: Set<String>
    private(set) var isLoading = false
    var errorMessage: String?

    private let provider: OneDriveProvider

    init(connection: ServerConnection) {
        provider = OneDriveProvider(connection: connection)
        selectedIds = connection.selectedLibraryIds ?? []
    }

    func load() async {
        guard folderStack.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            let root = try await provider.rootBrowserItem()
            folderStack = [root]
            items = try await provider.listBrowserItems(folderId: root.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func open(_ item: OneDriveBrowserItem) async {
        guard item.isFolder else { return }
        folderStack.append(item)
        await loadCurrentFolder()
    }

    func goToFolder(at index: Int) async {
        guard folderStack.indices.contains(index) else { return }
        folderStack.removeSubrange(folderStack.index(after: index)..<folderStack.endIndex)
        await loadCurrentFolder()
    }

    func isSelected(_ id: String) -> Bool { selectedIds.contains(id) }

    func toggle(_ item: OneDriveBrowserItem) {
        guard item.isFolder else { return }
        if selectedIds.remove(item.id) == nil {
            selectedIds.insert(item.id)
        }
    }

    private func loadCurrentFolder() async {
        guard let folder = folderStack.last else { return }
        isLoading = true
        errorMessage = nil
        do {
            items = try await provider.listBrowserItems(folderId: folder.id)
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
