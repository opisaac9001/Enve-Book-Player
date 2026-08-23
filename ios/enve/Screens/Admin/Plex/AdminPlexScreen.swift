import SwiftUI
import UIKit

struct AdminPlexScreen: View {
    let connection: ServerConnection
    @State private var model: AdminPlexModel

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @State private var showingInvite = false
    @State private var removingUser: PlexManagedUser?
    @State private var confirmEmptyTrash = false

    init(connection: ServerConnection) {
        self.connection = connection
        _model = State(initialValue: AdminPlexModel(connection: connection))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AdminHubHeader(connection: connection)

                if model.isLoading && !model.hasLoaded {
                    AdminLoadingRow("Asking the server for its ledger…")
                } else if !model.isOwner && model.hasLoaded {
                    adminGate
                } else if model.hasLoaded {
                    if let info = model.serverInfo { adminServerCard(info) }
                    adminActionsGrid
                    adminSessionsCard
                    if !model.librarySections.isEmpty { adminLibrariesCard }
                    adminUsersCard
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
        .task(id: model.isOwner) {

            guard model.isOwner else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await model.refreshSessions()
            }
        }
        .sheet(isPresented: $showingInvite) {
            AdminPlexInviteSheet(model: model)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .alert(
            "Remove access",
            isPresented: Binding(
                get: { removingUser != nil },
                set: { if !$0 { removingUser = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let user = removingUser {
                    Task { await model.removeSharedUser(user) }
                }
                removingUser = nil
            }
            Button("Cancel", role: .cancel) { removingUser = nil }
        } message: {
            Text("\(removingUser?.displayName ?? "They") will no longer be able to stream from this server.")
        }
        .alert("Empty all trash?", isPresented: $confirmEmptyTrash) {
            Button("Empty trash", role: .destructive) { Task { await model.emptyAllTrash() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently removes every trashed item across all libraries on this server. This can't be undone.")
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
                Text("Only the server's owner may tend it.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
            }
            Text("Managing users, scanning libraries, and maintenance belong to the Plex account that owns this server.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusError)
            }
        }
    }

    private func adminServerCard(_ info: PlexServerInfo) -> some View {
        SourcesCard {
            Overline("The server")
            AdminInfoRow(label: "Version", value: info.displayVersion)
            AdminInfoRow(label: "Platform", value: info.platform ?? "Unknown")
            AdminInfoRow(label: "Active transcodes", value: "\(info.transcoderActiveVideoSessions ?? 0)")
        }
    }

    private var adminActionsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            AdminActionTile(title: "Invite someone", systemImage: "person.badge.plus") {
                showingInvite = true
            }
            AdminActionTile(title: "Refresh all", systemImage: "arrow.clockwise") {
                Task { await model.refreshAll() }
            }
            AdminActionTile(title: "Tidy database", systemImage: "hammer") {
                Task { await model.optimizeDatabase() }
            }
            AdminActionTile(title: "Empty all trash", systemImage: "trash", tint: hearth.statusError) {
                confirmEmptyTrash = true
            }
        }
    }

    private var adminSessionsCard: some View {
        SourcesCard {
            Overline("Streaming now")
            if model.activeSessions.isEmpty {
                AdminEmptyText("No one is streaming right now.")
            } else {
                ForEach(model.activeSessions) { session in
                    adminSessionRow(session)
                }
            }
        }
    }

    private func adminSessionRow(_ session: PlexActiveSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    Text(session.user?.displayName ?? "Unknown listener")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(session.player?.isPlaying == true ? hearth.statusOK : hearth.statusWarn)
                        .frame(width: 7, height: 7)
                    Text(session.player?.state?.capitalized ?? "Unknown")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            AdminProgressLine(fraction: session.progressPercent / 100)
            HStack(spacing: 6) {
                Image(systemName: session.player?.isLocal == true ? "house" : "globe")
                    .font(.hearthUI(11))
                Text(session.player?.title ?? "Unknown device")
                    .font(.hearthCaption)
                    .lineLimit(1)
                Spacer()
                Text(session.transcodeSession?.transcodeDescription ?? "Direct play")
                    .font(.hearthUI(11, weight: .medium))
                    .foregroundStyle(session.isTranscoding ? hearth.statusWarn : hearth.statusOK)
                    .lineLimit(1)
                GlyphButton(systemImage: "xmark", size: 40, glyphSize: 13, label: "End this stream") {
                    Task { await model.terminateSession(session) }
                }
            }
            .foregroundStyle(hearth.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private var adminLibrariesCard: some View {
        SourcesCard {
            Overline("Libraries")
            ForEach(model.librarySections) { section in
                HStack(spacing: 12) {
                    Image(systemName: adminLibraryGlyph(section.type))
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.ember)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.displayName)
                            .font(.hearthUI(15, weight: .medium))
                            .foregroundStyle(hearth.text)
                        if section.isRefreshing {
                            Text("Scanning…")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.statusWarn)
                        } else if let scanned = section.lastScannedDate {
                            Text("Scanned \(scanned.formatted(.relative(presentation: .named)))")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                    }
                    Spacer()
                    Menu {
                        Button {
                            Task { await model.refreshLibrary(sectionKey: section.key) }
                        } label: {
                            Label("Scan library", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) {
                            Task { await model.emptyTrash(sectionKey: section.key) }
                        } label: {
                            Label("Empty trash", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.hearthUI(14, weight: .semibold))
                            .foregroundStyle(hearth.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Actions for \(section.displayName)")
                }
                .frame(minHeight: 44)
            }
        }
    }

    private var adminUsersCard: some View {
        SourcesCard {
            HStack {
                Overline("Shared with")
                Spacer()
                GlyphButton(systemImage: "person.badge.plus", size: 40, glyphSize: 15, label: "Invite someone") {
                    showingInvite = true
                }
            }
            if model.sharedUsers.isEmpty {
                AdminEmptyText("This server is shared with no one yet.")
            } else {
                ForEach(model.sharedUsers) { user in
                    HStack(spacing: 12) {
                        Image(systemName: user.isHomeUser ? "house" : "person")
                            .font(.hearthUI(15, weight: .medium))
                            .foregroundStyle(hearth.ember)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName)
                                .font(.hearthUI(15, weight: .medium))
                                .foregroundStyle(hearth.text)
                            HStack(spacing: 6) {
                                if user.isHomeUser { AdminTag(text: "Home") }
                                if user.isRestricted { AdminTag(text: "Restricted", color: hearth.statusWarn) }
                                if let email = user.email, !email.isEmpty {
                                    Text(email)
                                        .font(.hearthUI(11))
                                        .foregroundStyle(hearth.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer()
                        GlyphButton(systemImage: "person.fill.xmark", size: 40, glyphSize: 14, label: "Remove \(user.displayName)") {
                            removingUser = user
                        }
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }

    private func adminLibraryGlyph(_ type: String?) -> String {
        switch type {
        case "artist": "music.note.list"
        case "movie": "film"
        case "show": "tv"
        case "photo": "photo"
        default: "folder"
        }
    }
}

private struct AdminPlexInviteSheet: View {
    let model: AdminPlexModel

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var shareAll = true
    @State private var selectedKeys: Set<String> = []
    @State private var allowSync = true
    @State private var allowCameraUpload = false
    @State private var allowChannels = false

    var body: some View {
        AdminSheet(
            title: "Invite someone",
            confirmTitle: "Send the invitation",
            confirmDisabled: email.isEmpty,
            onConfirm: {
                let keys = shareAll ? model.librarySections.map(\.key) : Array(selectedKeys)
                Task {
                    await model.inviteUser(
                        email: email,
                        selectedLibraries: keys,
                        allowSync: allowSync,
                        allowCameraUpload: allowCameraUpload,
                        allowChannels: allowChannels
                    )
                }
                dismiss()
            }
        ) {
            SourcesField(label: "Email or username", text: $email, keyboard: .emailAddress)

            VStack(alignment: .leading, spacing: 10) {
                Overline("Libraries")
                SourcesToggleRow(
                    title: "Share every library",
                    subtitle: shareAll ? "They will see everything on this server." : nil,
                    isOn: $shareAll
                )
                if !shareAll {
                    ForEach(model.librarySections) { section in
                        SourcesToggleRow(
                            title: section.displayName,
                            isOn: Binding(
                                get: { selectedKeys.contains(section.key) },
                                set: { isOn in
                                    if isOn { selectedKeys.insert(section.key) } else { selectedKeys.remove(section.key) }
                                }
                            )
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Overline("Permissions")
                SourcesToggleRow(title: "Downloads & sync", isOn: $allowSync)
                SourcesToggleRow(title: "Camera upload", isOn: $allowCameraUpload)
                SourcesToggleRow(title: "Channels", isOn: $allowChannels)
            }
        }
        .onAppear {
            selectedKeys = Set(model.librarySections.map(\.key))
        }
    }
}
