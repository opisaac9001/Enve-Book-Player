import SwiftUI

struct AdminJellyfinScreen: View {
    let connection: ServerConnection
    @State private var model: AdminJellyfinModel

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @State private var showingAddUser = false
    @State private var deletingUser: JellyfinAdminUser?
    @State private var confirmingRestart = false

    init(connection: ServerConnection) {
        self.connection = connection
        _model = State(initialValue: AdminJellyfinModel(connection: connection))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AdminHubHeader(connection: connection)

                if model.isLoading && !model.hasLoaded {
                    AdminLoadingRow("Asking the server for its ledger…")
                } else if !model.isAuthorized && model.hasLoaded {
                    adminGate
                } else if model.hasLoaded {
                    if let info = model.systemInfo { adminServerCard(info) }
                    adminActionsGrid
                    adminSessionsCard
                    adminUsersCard
                    if !model.scheduledTasks.isEmpty { adminTasksCard }
                    if !model.libraries.isEmpty { adminLibrariesCard }
                    if !model.plugins.isEmpty { adminPluginsCard }
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
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await model.refreshAll() }
        .task {
            if !model.hasLoaded { await model.refreshAll() }
        }
        .sheet(isPresented: $showingAddUser) {
            AdminJellyfinAddUserSheet(model: model)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .alert(
            "Delete this account",
            isPresented: Binding(
                get: { deletingUser != nil },
                set: { if !$0 { deletingUser = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let user = deletingUser {
                    Task { await model.deleteUser(user) }
                }
                deletingUser = nil
            }
            Button("Cancel", role: .cancel) { deletingUser = nil }
        } message: {
            Text("\(deletingUser?.displayName ?? "The account") will be removed from the server.")
        }
        .alert("Restart the server", isPresented: $confirmingRestart) {
            Button("Restart", role: .destructive) {
                Task { await model.restartServer() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone streaming will be interrupted while it comes back.")
        }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
    }

    private var adminGate: some View {
        SourcesCard {
            HStack(spacing: 10) {
                Image(systemName: "lock")
                    .foregroundStyle(hearth.statusWarn)
                Text("Only administrators may tend this server.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
            }
            if let error = model.error {
                Text(error)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusError)
            }
        }
    }

    private func adminServerCard(_ info: JellyfinSystemInfo) -> some View {
        SourcesCard {
            Overline("The server")
            AdminInfoRow(label: "Name", value: info.displayName)
            AdminInfoRow(label: "Version", value: info.displayVersion)
            AdminInfoRow(label: "Operating system", value: info.OperatingSystem ?? "Unknown")
            if info.needsRestart {
                AdminInfoRow(label: "Status", value: "Restart required", valueColor: hearth.statusWarn)
            }
            if info.hasUpdate {
                AdminInfoRow(label: "Update", value: "Available", valueColor: hearth.statusOK)
            }
        }
    }

    private var adminActionsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            AdminActionTile(title: "Add an account", systemImage: "person.badge.plus") {
                showingAddUser = true
            }
            AdminActionTile(title: "Restart server", systemImage: "arrow.clockwise.circle", tint: hearth.statusWarn) {
                confirmingRestart = true
            }
        }
    }

    private var adminSessionsCard: some View {
        let playing = model.activeSessions.filter { $0.NowPlayingItem != nil }
        return SourcesCard {
            Overline("Streaming now")
            if playing.isEmpty {
                AdminEmptyText("No one is streaming right now.")
            } else {
                ForEach(playing) { session in
                    adminSessionRow(session)
                }
            }
        }
    }

    private func adminSessionRow(_ session: JellyfinActiveSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.NowPlayingItem?.displayTitle ?? "Untitled")
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    Text(session.displayName)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(session.isPlaying ? hearth.statusOK : hearth.statusWarn)
                        .frame(width: 7, height: 7)
                    Text(session.PlayState?.IsPaused == true ? "Paused" : "Playing")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            if let item = session.NowPlayingItem, item.durationSeconds > 0 {
                AdminProgressLine(fraction: (session.PlayState?.positionSeconds ?? 0) / item.durationSeconds)
            }
            HStack {
                Text(session.deviceInfo)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(1)
                Spacer()
                Text(session.PlayState?.PlayMethod ?? "Unknown")
                    .font(.hearthUI(11, weight: .medium))
                    .foregroundStyle(session.PlayState?.isDirectPlay == true ? hearth.statusOK : hearth.statusWarn)
            }
        }
        .padding(.vertical, 4)
    }

    private var adminUsersCard: some View {
        SourcesCard {
            HStack {
                Overline("Accounts")
                Spacer()
                GlyphButton(systemImage: "person.badge.plus", size: 40, glyphSize: 15, label: "Add an account") {
                    showingAddUser = true
                }
            }
            if model.users.isEmpty {
                AdminEmptyText("No accounts to show.")
            } else {
                ForEach(model.users) { user in
                    adminUserRow(user)
                }
            }
        }
    }

    private func adminUserRow(_ user: JellyfinAdminUser) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(user.displayName)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    if user.isAdmin { AdminTag(text: "Admin", color: hearth.ember) }
                    if user.isDisabled { AdminTag(text: "Disabled", color: hearth.statusError) }
                }
                if let activity = user.lastActivityDate {
                    Text("Seen \(activity.formatted(.relative(presentation: .named)))")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            Spacer()
            Menu {
                Button {
                    Task { await model.toggleUserDisabled(user) }
                } label: {
                    Label(
                        user.isDisabled ? "Enable account" : "Disable account",
                        systemImage: user.isDisabled ? "checkmark.circle" : "xmark.circle"
                    )
                }
                if !user.isAdmin {
                    Button(role: .destructive) {
                        deletingUser = user
                    } label: {
                        Label("Delete account", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.hearthUI(14, weight: .semibold))
                    .foregroundStyle(hearth.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(user.displayName)")
        }
        .frame(minHeight: 44)
    }

    private var adminTasksCard: some View {
        let visible = model.scheduledTasks.filter { $0.IsHidden != true }
        return SourcesCard {
            Overline("Scheduled tasks")
            if visible.isEmpty {
                AdminEmptyText("The server keeps no visible tasks.")
            } else {
                ForEach(visible) { task in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.displayName)
                                .font(.hearthUI(14, weight: .medium))
                                .foregroundStyle(hearth.text)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if task.isRunning {
                                    Text("Running · \(Int(task.progress))%")
                                        .foregroundStyle(hearth.statusWarn)
                                } else if let result = task.LastExecutionResult, !result.wasSuccessful {
                                    Text(result.Status ?? "Did not finish")
                                        .foregroundStyle(hearth.statusError)
                                } else if let category = task.Category {
                                    Text(category)
                                        .foregroundStyle(hearth.textTertiary)
                                }
                            }
                            .font(.hearthUI(11))
                        }
                        Spacer()
                        GlyphButton(systemImage: "play", size: 40, glyphSize: 13, label: "Run \(task.displayName)") {
                            Task { await model.runTask(task) }
                        }
                        .disabled(task.isRunning)
                        .opacity(task.isRunning ? 0.4 : 1)
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }

    private var adminLibrariesCard: some View {
        SourcesCard {
            Overline("Libraries")
            ForEach(model.libraries) { library in
                HStack(spacing: 12) {
                    Image(systemName: adminLibraryGlyph(library.collectionType))
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.ember)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(library.name)
                            .font(.hearthUI(15, weight: .medium))
                            .foregroundStyle(hearth.text)
                        Text("\(library.itemCount) items")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                    Spacer()
                    if model.isLibraryHidden(library.id) {
                        AdminTag(text: "Hidden")
                    }
                    Menu {
                        Button {
                            Task { await model.refreshLibrary(libraryId: library.id) }
                        } label: {
                            Label("Scan library", systemImage: "arrow.clockwise")
                        }
                        Button {
                            model.toggleLibraryHidden(library.id)
                        } label: {
                            if model.isLibraryHidden(library.id) {
                                Label("Show in this app", systemImage: "eye")
                            } else {
                                Label("Hide from this app", systemImage: "eye.slash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.hearthUI(14, weight: .semibold))
                            .foregroundStyle(hearth.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Actions for \(library.name)")
                }
                .frame(minHeight: 44)
            }
        }
    }

    private var adminPluginsCard: some View {
        SourcesCard {
            Overline("Plugins")
            ForEach(model.plugins) { plugin in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.displayName)
                            .font(.hearthUI(14, weight: .medium))
                            .foregroundStyle(hearth.text)
                            .lineLimit(1)
                        Text(plugin.displayVersion)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                    Spacer()
                    AdminTag(
                        text: plugin.Status ?? "Unknown",
                        color: plugin.isActive ? hearth.statusOK : nil
                    )
                }
                .frame(minHeight: 36)
            }
        }
    }

    private func adminLibraryGlyph(_ type: String?) -> String {
        switch type?.lowercased() {
        case "music": "music.note.list"
        case "movies": "film"
        case "tvshows": "tv"
        case "books": "book"
        default: "folder"
        }
    }
}

private struct AdminJellyfinAddUserSheet: View {
    let model: AdminJellyfinModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""

    var body: some View {
        AdminSheet(
            title: "A new account",
            confirmTitle: "Create",
            confirmDisabled: name.isEmpty,
            onConfirm: {
                Task {
                    await model.createUser(name: name, password: password.isEmpty ? nil : password)
                }
                dismiss()
            }
        ) {
            SourcesField(label: "Username", text: $name)
            SourcesField(label: "Password (optional)", text: $password, secure: true)
        }
    }
}
