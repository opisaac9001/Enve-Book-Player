import SwiftUI

struct AdminStorytellerScreen: View {
    let connection: ServerConnection
    @State private var model: AdminStorytellerModel

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    init(connection: ServerConnection) {
        self.connection = connection
        _model = State(initialValue: AdminStorytellerModel(connection: connection))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AdminHubHeader(connection: connection)

                if model.isLoading && !model.hasLoaded {
                    AdminLoadingRow("Asking Storyteller what this account can manage…")
                } else if model.hasLoaded {
                    if let user = model.currentUser { accountCard(user) }
                    overviewCard
                    toolsCard
                    if !model.canListBooks || !model.shelvesSupported || !model.canProcessBooks {
                        permissionsCard
                    }
                    QuietButton(title: "Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refreshAll() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await model.refreshAll() }
        .task {
            if !model.hasLoaded { await model.refreshAll() }
        }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
    }

    private func accountCard(_ user: StorytellerUser) -> some View {
        SourcesCard {
            Overline("Connected as")
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(hearth.emberSoft)
                        .frame(width: 46, height: 46)
                    Text(String((user.name.isEmpty ? user.username : user.name).prefix(1)).uppercased())
                        .font(.hearthDisplay(19))
                        .foregroundStyle(hearth.ember)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(user.name.isEmpty ? user.username : user.name)
                        .font(.hearthUI(16, weight: .semibold))
                        .foregroundStyle(hearth.text)
                    Text(user.email ?? user.username)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
            }
        }
    }

    private var overviewCard: some View {
        SourcesCard {
            Overline("At a glance")
            HStack(alignment: .top) {
                AdminStat(
                    value: model.canListBooks && model.shelvesSupported ? "\(model.shelves.count)" : "—",
                    label: "Shelves"
                )
                AdminStat(
                    value: model.canProcessBooks ? "\(model.processingBooks.count)" : "—",
                    label: "Alignable"
                )
                AdminStat(
                    value: model.canProcessBooks
                        ? "\(model.processingBooks.count(where: \.isProcessing))"
                        : "—",
                    label: "Running"
                )
            }
            if let facets = model.alignmentFacets {
                AdminInfoRow(label: "Alignment reports", value: facets.total.formatted())
                AdminInfoRow(label: "Muted chapters", value: facets.muted.formatted())
            }
        }
    }

    private var toolsCard: some View {
        SourcesCard {
            if model.canListBooks && model.shelvesSupported {
                AdminLinkRow(
                    systemImage: "books.vertical",
                    title: "Your shelves",
                    caption: model.shelves.isEmpty ? "Create your first shelf" : "\(model.shelves.count) saved"
                ) {
                    AdminStorytellerShelvesScreen(model: model)
                }
            }
            if model.canProcessBooks {
                AdminLinkRow(
                    systemImage: "waveform",
                    title: "Alignment quality",
                    caption: "Reports, processing, and restarts"
                ) {
                    AdminStorytellerProcessingScreen(model: model)
                }
            }
            if (!model.canListBooks || !model.shelvesSupported)
                && !model.canProcessBooks
            {
                AdminEmptyText("This account has no Storyteller management tools available.")
            }
        }
    }

    private var permissionsCard: some View {
        SourcesCard {
            Overline("Tool availability")
            if !model.canListBooks {
                permissionRow("Shelves", detail: "Requires bookList")
            } else if !model.shelvesSupported {
                permissionRow(
                    "Shelves",
                    detail: "Not supported by this server",
                    systemImage: "xmark.circle"
                )
            }
            if !model.canProcessBooks {
                permissionRow("Alignment", detail: "Requires bookProcess")
            }
        }
    }

    private func permissionRow(_ title: String, detail: String, systemImage: String = "lock") -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.hearthUI(13, weight: .medium))
                .foregroundStyle(hearth.textTertiary)
            Text(title)
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.text)
            Spacer()
            Text(detail)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
    }
}

private enum StorytellerShelfEditorTarget: Identifiable {
    case create
    case rename(StorytellerShelf)

    var id: String {
        switch self {
        case .create: return "create"
        case .rename(let shelf): return shelf.id
        }
    }

    var shelf: StorytellerShelf? {
        if case .rename(let shelf) = self { return shelf }
        return nil
    }
}

struct AdminStorytellerShelvesScreen: View {
    let model: AdminStorytellerModel

    @Environment(\.hearth) private var hearth
    @State private var editorTarget: StorytellerShelfEditorTarget?
    @State private var pendingDelete: StorytellerShelf?

    var body: some View {
        AdminSubScreen(overline: "Storyteller", title: "Your shelves") {
            HStack {
                Text("Personal shelves belong to this Storyteller account.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                Spacer()
                Button {
                    editorTarget = .create
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.hearthUI(22, weight: .medium))
                        .foregroundStyle(hearth.ember)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Create shelf")
            }

            if model.shelves.isEmpty {
                SourcesCard {
                    AdminEmptyText("No shelves yet. Create one to organize books on every Storyteller client.")
                }
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(model.shelves) { shelf in
                        SourcesCard {
                            HStack(spacing: 12) {
                                NavigationLink {
                                    AdminStorytellerShelfMembershipScreen(
                                        connection: model.connection,
                                        parent: model,
                                        shelf: shelf
                                    )
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: shelf.hasFilter ? "sparkles" : "books.vertical")
                                            .font(.hearthUI(16, weight: .medium))
                                            .foregroundStyle(hearth.ember)
                                            .frame(width: 32, height: 32)
                                            .background(hearth.emberSoft, in: Circle())
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(shelf.name)
                                                .font(.hearthUI(15, weight: .semibold))
                                                .foregroundStyle(hearth.text)
                                            Text("\(shelf.books.count) pinned \(shelf.books.count == 1 ? "book" : "books")")
                                                .font(.hearthCaption)
                                                .foregroundStyle(hearth.textSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.hearthUI(12, weight: .semibold))
                                            .foregroundStyle(hearth.textTertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PressableStyle())
                                Menu {
                                    Button("Rename", systemImage: "pencil") {
                                        editorTarget = .rename(shelf)
                                    }
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        pendingDelete = shelf
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.hearthUI(20))
                                        .foregroundStyle(hearth.textSecondary)
                                        .frame(width: 40, height: 40)
                                }
                                .accessibilityLabel("Actions for \(shelf.name)")
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            AdminStorytellerShelfEditor(target: target) { name in
                if let shelf = target.shelf {
                    await model.renameShelf(shelf, name: name)
                } else {
                    await model.createShelf(name: name)
                }
            }
            .enveEnvironment()
            .hearthPresentationBackground()
        }
        .alert(
            "Delete shelf?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { shelf in
            Button("Delete", role: .destructive) {
                Task { await model.deleteShelf(shelf) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { shelf in
            Text("“\(shelf.name)” will be removed from your Storyteller account.")
        }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
    }
}

private struct AdminStorytellerShelfEditor: View {
    let target: StorytellerShelfEditorTarget
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false

    init(target: StorytellerShelfEditorTarget, onSave: @escaping (String) async -> Void) {
        self.target = target
        self.onSave = onSave
        _name = State(initialValue: target.shelf?.name ?? "")
    }

    var body: some View {
        AdminSheet(
            title: target.shelf == nil ? "New shelf" : "Rename shelf",
            confirmTitle: target.shelf == nil ? "Create" : "Save",
            confirmDisabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving
        ) {
            isSaving = true
            Task {
                await onSave(name)
                dismiss()
            }
        } content: {
            SourcesField(label: "Name", text: $name, placeholder: "Shelf name")
        }
    }
}
