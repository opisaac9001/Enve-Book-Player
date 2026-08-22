import SwiftUI

struct AdminABSLibrariesScreen: View {
    let model: AdminABSModel

    @Environment(\.hearth) private var hearth
    @State private var showingAddLibrary = false
    @State private var editingLibrary: ABSLibrary?

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Libraries") {
            if model.isLoading && model.libraries.isEmpty {
                AdminLoadingRow("Fetching the libraries…")
            } else if model.libraries.isEmpty {
                AdminEmptyText("The server has no libraries yet. Build the first one below.")
            }

            ForEach(model.libraries) { library in
                adminLibraryCard(library)
            }

            QuietButton(title: "Add a library", systemImage: "plus") {
                showingAddLibrary = true
            }
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingAddLibrary) {
            AdminABSAddLibrarySheet(model: model)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .sheet(item: $editingLibrary) { library in
            AdminABSEditLibrarySheet(model: model, library: library)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
    }

    private func adminLibraryCard(_ library: ABSLibrary) -> some View {
        SourcesCard {
            HStack(alignment: .firstTextBaseline) {
                Text(library.name)
                    .font(.hearthUI(16, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Spacer()
                AdminTag(text: library.mediaType?.capitalized ?? "Unknown")
            }
            if let folders = library.folders, !folders.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(folders, id: \.id) { folder in
                        Text(folder.fullPath)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            HStack(spacing: 10) {
                QuietButton(title: "Scan", systemImage: "magnifyingglass") {
                    Task { await model.scanLibrary(id: library.id) }
                }
                QuietButton(title: "Purge cache", systemImage: "trash") {
                    Task { await model.purgeLibraryCache(id: library.id) }
                }
                Spacer()
                GlyphButton(systemImage: "pencil", size: 40, glyphSize: 15, label: "Edit \(library.name)") {
                    editingLibrary = library
                }
            }
        }
    }
}

private struct AdminABSAddLibrarySheet: View {
    let model: AdminABSModel

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var mediaType = "book"
    @State private var path = ""
    @State private var browsing = false

    var body: some View {
        AdminSheet(
            title: "A new library",
            confirmTitle: "Create",
            confirmDisabled: name.isEmpty || path.isEmpty,
            onConfirm: {
                Task {
                    await model.createLibrary(
                        ABSLibraryRequest(
                            name: name,
                            mediaType: mediaType,
                            folders: [ABSLibraryFolderPayload(fullPath: path)]
                        )
                    )
                    dismiss()
                }
            }
        ) {
            SourcesField(label: "Name", text: $name)
            VStack(alignment: .leading, spacing: 7) {
                Overline("Holds")
                HStack(spacing: 8) {
                    HearthChip(title: "Books", isSelected: mediaType == "book") { mediaType = "book" }
                    HearthChip(title: "Podcasts", isSelected: mediaType == "podcast") { mediaType = "podcast" }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                SourcesField(label: "Folder on the server", text: $path, placeholder: "/audiobooks")
                QuietButton(title: "Browse the server's folders", systemImage: "folder") {
                    browsing = true
                }
            }
        }
        .sheet(isPresented: $browsing) {
            AdminABSFolderBrowser(model: model, selectedPath: $path)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
    }
}

private struct AdminABSEditLibrarySheet: View {
    let model: AdminABSModel
    let library: ABSLibrary

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var mediaType: String
    @State private var confirmingDelete = false

    init(model: AdminABSModel, library: ABSLibrary) {
        self.model = model
        self.library = library
        _name = State(initialValue: library.name)
        _mediaType = State(initialValue: library.mediaType ?? "book")
    }

    var body: some View {
        AdminSheet(
            title: library.name,
            confirmTitle: "Save",
            confirmDisabled: name.isEmpty,
            onConfirm: {
                Task {
                    await model.updateLibrary(
                        id: library.id,
                        request: ABSLibraryRequest(
                            name: name,
                            mediaType: mediaType,
                            folders: nil
                        )
                    )
                    dismiss()
                }
            }
        ) {
            SourcesField(label: "Name", text: $name)
            VStack(alignment: .leading, spacing: 7) {
                Overline("Holds")
                HStack(spacing: 8) {
                    HearthChip(title: "Books", isSelected: mediaType == "book") { mediaType = "book" }
                    HearthChip(title: "Podcasts", isSelected: mediaType == "podcast") { mediaType = "podcast" }
                }
            }
            AdminDestructiveButton(title: "Delete this library", systemImage: "trash") {
                confirmingDelete = true
            }
        }
        .alert("Delete this library", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.deleteLibrary(id: library.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(library.name) will be removed from the server. The files on disk stay where they are.")
        }
    }
}

private struct AdminABSFolderBrowser: View {
    let model: AdminABSModel
    @Binding var selectedPath: String

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = "/"
    @State private var folders: [ABSFilesystemItem] = []
    @State private var pathHistory: [String] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Overline("Choose a folder")
                        Text(currentPath)
                            .font(.hearthDisplay(20))
                            .foregroundStyle(hearth.text)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }

                    if currentPath != "/" {
                        adminRow(glyph: "arrow.up", title: "Up one level", caption: nil) {
                            adminNavigateUp()
                        }
                    }

                    if isLoading {
                        AdminLoadingRow("Looking inside…")
                    } else if let loadError {
                        Text(loadError)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.statusError)
                    } else if folders.isEmpty {
                        AdminEmptyText("Nothing further down this path.")
                    } else {
                        ForEach(folders) { folder in
                            adminRow(glyph: "folder", title: folder.displayName, caption: folder.bestPath) {
                                if let next = folder.bestPath {
                                    adminNavigateInto(next)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 12) {
                QuietButton(title: "Cancel") { dismiss() }
                Spacer()
                EmberButton(title: "Choose this folder") {
                    selectedPath = currentPath
                    dismiss()
                }
                .disabled(currentPath.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .presentationDragIndicator(.visible)
        .task { await adminLoad(path: currentPath) }
    }

    private func adminRow(glyph: String, title: String, caption: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: glyph)
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.ember)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    if let caption {
                        Text(caption)
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func adminNavigateInto(_ path: String) {
        pathHistory.append(currentPath)
        currentPath = path
        Task { await adminLoad(path: path) }
    }

    private func adminNavigateUp() {
        if let previous = pathHistory.popLast() {
            currentPath = previous
        } else {
            let components = currentPath.split(separator: "/")
            currentPath =
                components.count > 1
                ? "/" + components.dropLast().joined(separator: "/")
                : "/"
        }
        Task { await adminLoad(path: currentPath) }
    }

    private func adminLoad(path: String) async {
        isLoading = true
        loadError = nil
        do {
            let items = try await model.filesystemFolders(path: path)
            folders = items.filter { $0.bestPath != nil }
        } catch {
            loadError = error.localizedDescription
            folders = []
        }
        isLoading = false
    }
}
