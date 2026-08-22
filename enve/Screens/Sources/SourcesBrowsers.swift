import SwiftUI

struct SourcesWebDAVBrowser: View {
    let server: WebDAVServerConfig
    let onSelectPaths: ([String]) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var currentPath: String
    @State private var selectedPaths: [String]
    @State private var entries: [RemoteFileEntry] = []
    @State private var isLoading = false
    @State private var error: String?

    init(server: WebDAVServerConfig, onSelectPath: @escaping (String) -> Void) {
        self.init(
            server: server,
            onSelectPaths: { paths in
                onSelectPath(paths.first ?? "/")
            }
        )
    }

    init(server: WebDAVServerConfig, onSelectPaths: @escaping ([String]) -> Void) {
        self.server = server
        self.onSelectPaths = onSelectPaths
        _currentPath = State(initialValue: server.rootPath)
        _selectedPaths = State(initialValue: Self.normalizedUnique(server.indexedPaths))
    }

    var body: some View {
        NavigationStack {
            SourcesBrowserChrome(
                title: currentPath == "/" ? server.name : (currentPath as NSString).lastPathComponent,
                isLoading: isLoading,
                error: error,
                isEmpty: entries.isEmpty,
                onRetry: loadDirectory,
                canGoUp: currentPath != server.rootPath,
                onUp: goUp,
                onCancel: { dismiss() },
                onUseFolder: {
                    onSelectPaths(pathsForCommit)
                    dismiss()
                },
                primaryTitle: primaryActionTitle,
                extraAction: (
                    title: isCurrentPathSelected ? "Remove folder" : "Add folder",
                    action: toggleCurrentPath
                ),
                footer: {
                    selectedFoldersView
                }
            ) {
                ForEach(entries, id: \.id) { entry in
                    let entryPath = Self.normalizedPath(entry.path)
                    let isSelected = selectedPaths.contains(entryPath)
                    HStack(spacing: 0) {
                        Button {
                            guard entry.isDirectory else { return }
                            toggleSelectedPath(entry.path)
                        } label: {
                            SourcesBrowserRow(
                                name: entry.name,
                                isFolder: entry.isDirectory,
                                size: entry.size,
                                isSelected: isSelected,
                                showsSelectionControl: entry.isDirectory,
                                showsChevron: false
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(PressableStyle())
                        .disabled(!entry.isDirectory)

                        if entry.isDirectory {
                            Button {
                                currentPath = entry.path
                                loadDirectory()
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.hearthUI(18, weight: .semibold))
                                    .foregroundStyle(hearth.textTertiary)
                                    .frame(width: 38, height: 38)
                            }
                            .accessibilityLabel("Open \(entry.name)")
                        }
                    }
                }
            }
        }
        .onAppear(perform: loadDirectory)
    }

    private var isCurrentPathSelected: Bool {
        selectedPaths.contains(Self.normalizedPath(currentPath))
    }

    private var pathsForCommit: [String] {
        let current = Self.normalizedPath(currentPath)
        let initialRoot = Self.normalizedPath(server.rootPath)
        if selectedPaths.isEmpty { return [current] }
        if selectedPaths.count == 1, selectedPaths[0] == initialRoot, current != initialRoot {
            return [current]
        }
        return selectedPaths
    }

    private var primaryActionTitle: String {
        if selectedPaths.count > 1 {
            return "Import \(selectedPaths.count) folders"
        }
        if selectedPaths.count == 1 {
            return "Import selected folder"
        }
        return Self.normalizedPath(currentPath) == "/" ? "Import all" : "Use this folder"
    }

    @ViewBuilder
    private var selectedFoldersView: some View {
        if !selectedPaths.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Overline("Selected folders")
                ForEach(selectedPaths, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.hearthUI(12))
                            .foregroundStyle(hearth.ember)
                        Text(path)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            selectedPaths.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.hearthUI(11, weight: .semibold))
                                .foregroundStyle(hearth.textTertiary)
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityLabel("Remove \(path)")
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func toggleCurrentPath() {
        toggleSelectedPath(currentPath)
    }

    private func toggleSelectedPath(_ path: String) {
        let normalized = Self.normalizedPath(path)
        if selectedPaths.contains(normalized) {
            selectedPaths.removeAll { $0 == normalized }
        } else {
            selectedPaths.append(normalized)
        }
    }

    private func loadDirectory() {
        isLoading = true
        error = nil
        Task {
            do {
                let result = try await RemoteImportService.shared.listWebDAVDirectory(server: server, path: currentPath)
                entries = result.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                isLoading = false
            } catch {
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func goUp() {
        currentPath = (currentPath as NSString).deletingLastPathComponent
        if currentPath.isEmpty { currentPath = "/" }
        loadDirectory()
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = trimmed.isEmpty ? "/" : trimmed
        if !normalized.hasPrefix("/") { normalized = "/" + normalized }
        if normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    private static func normalizedUnique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let normalized = normalizedPath(path)
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }
}

struct SourcesCloudFolderBrowser: View {
    let connection: ServerConnection
    let onFolderSelected: (String) -> Void
    var onScanAll: (() -> Void)?

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [CloudFolderItem] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var navigationStack: [(id: String?, name: String)] = []

    private var currentFolderId: String? { navigationStack.last?.id }

    var body: some View {
        NavigationStack {
            SourcesBrowserChrome(
                title: navigationStack.last?.name ?? connection.name,
                isLoading: isLoading,
                error: error,
                isEmpty: entries.isEmpty,
                onRetry: loadEntries,
                canGoUp: navigationStack.count > 1,
                onUp: goUp,
                onCancel: { dismiss() },
                onUseFolder: {
                    onFolderSelected(currentFolderId ?? "/")
                    dismiss()
                },
                extraAction: onScanAll.map { scanAll in
                    (
                        title: "Scan everything",
                        action: {
                            scanAll()
                            dismiss()
                        }
                    )
                }
            ) {
                ForEach(entries) { entry in
                    Button {
                        guard entry.isFolder else { return }
                        navigationStack.append((id: entry.path, name: entry.name))
                        loadEntries()
                    } label: {
                        SourcesBrowserRow(name: entry.name, isFolder: entry.isFolder, size: entry.size)
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(!entry.isFolder)
                }
            }
        }
        .onAppear {
            navigationStack = [(id: nil, name: connection.name)]
            loadEntries()
        }
    }

    private func goUp() {
        guard navigationStack.count > 1 else { return }
        navigationStack.removeLast()
        loadEntries()
    }

    private func loadEntries() {
        isLoading = true
        error = nil
        Task {
            do {
                let items: [CloudFolderItem]
                switch connection.type {
                case .realdebrid:
                    let provider = RealDebridProvider(connection: connection)
                    if let folderId = currentFolderId {
                        items = try await provider.listFolderEntries(path: folderId)
                    } else {
                        items = try await provider.listRootEntries()
                    }
                case .premiumize:
                    let provider = PremiumizeProvider(connection: connection)
                    if let folderId = currentFolderId {
                        items = try await provider.listFolderEntries(folderId: folderId)
                    } else {
                        items = try await provider.listRootEntries()
                    }
                default:
                    items = []
                }
                entries = items
                isLoading = false
            } catch {
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}

private struct SourcesBrowserRow: View {
    let name: String
    let isFolder: Bool
    let size: Int64?
    let isSelected: Bool
    let showsSelectionControl: Bool
    let showsChevron: Bool

    @Environment(\.hearth) private var hearth

    init(
        name: String,
        isFolder: Bool,
        size: Int64?,
        isSelected: Bool = false,
        showsSelectionControl: Bool = false,
        showsChevron: Bool = true
    ) {
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.isSelected = isSelected
        self.showsSelectionControl = showsSelectionControl
        self.showsChevron = showsChevron
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isFolder ? "folder" : "doc")
                .font(.hearthUI(15))
                .foregroundStyle(isFolder ? hearth.ember : hearth.textTertiary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.hearthBody)
                    .foregroundStyle(isFolder ? hearth.text : hearth.textSecondary)
                    .lineLimit(1)
                if let size, !isFolder {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            Spacer()
            if showsSelectionControl {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.hearthUI(17, weight: .semibold))
                    .foregroundStyle(isSelected ? hearth.ember : hearth.textTertiary)
            } else if isFolder && showsChevron {
                Image(systemName: "chevron.right")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct SourcesBrowserChrome<Rows: View>: View {
    let title: String
    let isLoading: Bool
    let error: String?
    let isEmpty: Bool
    let onRetry: () -> Void
    let canGoUp: Bool
    let onUp: () -> Void
    let onCancel: () -> Void
    let onUseFolder: () -> Void
    let extraAction: (title: String, action: () -> Void)?
    let primaryTitle: String
    let footer: AnyView
    let rows: Rows

    @Environment(\.hearth) private var hearth

    init(
        title: String,
        isLoading: Bool,
        error: String?,
        isEmpty: Bool,
        onRetry: @escaping () -> Void,
        canGoUp: Bool,
        onUp: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onUseFolder: @escaping () -> Void,
        primaryTitle: String = "Use this folder",
        extraAction: (title: String, action: () -> Void)? = nil,
        @ViewBuilder footer: () -> some View = { EmptyView() },
        @ViewBuilder rows: () -> Rows
    ) {
        self.title = title
        self.isLoading = isLoading
        self.error = error
        self.isEmpty = isEmpty
        self.onRetry = onRetry
        self.canGoUp = canGoUp
        self.onUp = onUp
        self.onCancel = onCancel
        self.onUseFolder = onUseFolder
        self.extraAction = extraAction
        self.primaryTitle = primaryTitle
        self.footer = AnyView(footer())
        self.rows = rows()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Overline("Choose a folder")
                    Text(title)
                        .font(.hearthDisplay(24))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                }

                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().tint(hearth.ember)
                        Text("Reading the shelves…")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                } else if let error {
                    VStack(alignment: .leading, spacing: 10) {
                        SourcesErrorText(message: error)
                        QuietButton(title: "Try again", systemImage: nil) { onRetry() }
                    }
                } else if isEmpty {
                    Text("This folder is empty.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                } else {
                    SourcesCard { rows }
                }
                footer
            }
            .padding(24)
            .padding(.bottom, 80)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if canGoUp {
                    Button {
                        onUp()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .foregroundStyle(hearth.text)
                    .accessibilityLabel("Up one folder")
                } else {
                    Button("Cancel") { onCancel() }
                        .foregroundStyle(hearth.textSecondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                if let extraAction {
                    QuietButton(title: extraAction.title, systemImage: nil) { extraAction.action() }
                }
                EmberButton(title: primaryTitle, systemImage: nil, tint: nil) { onUseFolder() }
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }
}
