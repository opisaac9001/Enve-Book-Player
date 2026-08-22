import SwiftUI
import UIKit

struct AdminGrimmoryUsersScreen: View {
    let model: AdminGrimmoryModel

    @Environment(\.hearth) private var hearth
    @State private var showingAdd = false
    @State private var editingUser: GrimmoryManagedUser?
    @State private var passwordUser: GrimmoryManagedUser?
    @State private var deletingUser: GrimmoryManagedUser?

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Users") {
            if model.currentUser?.isAdmin != true {
                SourcesCard {
                    HStack(spacing: 10) {
                        Image(systemName: "lock")
                            .foregroundStyle(hearth.statusWarn)
                        Text("Only administrators may manage accounts.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.text)
                    }
                }
            } else {
                SourcesCard {
                    Overline("The roster")
                    HStack(alignment: .top) {
                        AdminStat(value: "\(model.users.count)", label: "Accounts")
                        AdminStat(value: "\(model.users.filter(\.isAdmin).count)", label: "Admins")
                        AdminStat(
                            value: "\(model.users.filter { $0.isDefaultPassword == true }.count)",
                            label: "Default password"
                        )
                    }
                }

                QuietButton(title: "Add an account", systemImage: "person.badge.plus") {
                    showingAdd = true
                }
                .frame(maxWidth: .infinity)

                if model.users.isEmpty {
                    AdminEmptyText(model.isLoading ? "Fetching the accounts…" : "No accounts to show.")
                }

                ForEach(model.users) { user in
                    adminUserCard(user)
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AdminGrimmoryUserSheet(model: model, editing: nil)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .sheet(item: $editingUser) { user in
            AdminGrimmoryUserSheet(model: model, editing: user)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .sheet(item: $passwordUser) { user in
            AdminGrimmoryPasswordSheet(model: model, user: user)
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
                    Task { await model.deleteUser(id: user.id) }
                }
                deletingUser = nil
            }
            Button("Cancel", role: .cancel) { deletingUser = nil }
        } message: {
            Text("\(deletingUser?.displayName ?? "The account") will be removed for good.")
        }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
    }

    private func adminUserCard(_ user: GrimmoryManagedUser) -> some View {
        SourcesCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(hearth.emberSoft)
                        .frame(width: 44, height: 44)
                    Text(String(user.displayName.prefix(1)).uppercased())
                        .font(.hearthDisplay(18))
                        .foregroundStyle(hearth.ember)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(user.displayName)
                            .font(.hearthUI(15, weight: .semibold))
                            .foregroundStyle(hearth.text)
                        if user.isAdmin { AdminTag(text: "Admin", color: hearth.ember) }
                    }
                    if let email = user.email, !email.isEmpty {
                        Text(email)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                    Text(adminLibraryAccess(for: user))
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                        .lineLimit(2)
                }
                Spacer()
                if user.id == model.currentUser?.id {
                    Text("You")
                        .font(.hearthUI(12, weight: .medium))
                        .foregroundStyle(hearth.statusOK)
                } else {
                    Menu {
                        Button {
                            editingUser = user
                        } label: {
                            Label("Edit account", systemImage: "pencil")
                        }
                        Button {
                            passwordUser = user
                        } label: {
                            Label("Change password", systemImage: "key")
                        }
                        Divider()
                        Button(role: .destructive) {
                            deletingUser = user
                        } label: {
                            Label("Delete account", systemImage: "trash")
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
            }

            let tags = adminPermissionTags(user.permissions)
            if !tags.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 4)], alignment: .leading, spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        AdminTag(text: tag)
                    }
                }
            }
        }
    }

    private func adminPermissionTags(_ permissions: GrimmoryPermissions?) -> [String] {
        guard let p = permissions else { return [] }
        var tags: [String] = []
        if p.canDownload == true { tags.append("Download") }
        if p.canUpload == true { tags.append("Upload") }
        if p.canEditMetadata == true { tags.append("Edit") }
        if p.canDeleteBook == true { tags.append("Delete") }
        if p.canAccessOpds == true { tags.append("OPDS") }
        if p.canManageLibrary == true { tags.append("Library") }
        if p.canSyncKoReader == true { tags.append("KOReader") }
        if p.canSyncKobo == true { tags.append("Kobo") }
        if p.canEmailBook == true { tags.append("Email") }
        if p.canAccessBookdrop == true { tags.append("Bookdrop") }
        return tags
    }

    private func adminLibraryAccess(for user: GrimmoryManagedUser) -> String {
        guard let assigned = user.effectiveAssignedLibraries else { return "Access to every library" }
        if assigned.isEmpty { return "No libraries assigned" }
        let names = assigned.compactMap { id in
            model.libraries.first { Int($0.id) == id }?.name
        }
        if names.isEmpty {
            return "Access to \(assigned.count) librar\(assigned.count == 1 ? "y" : "ies")"
        }
        let preview = names.prefix(2).joined(separator: ", ")
        return names.count <= 2 ? "Access: \(preview)" : "Access: \(preview) and \(names.count - 2) more"
    }
}

private struct AdminGrimmoryPermissionDraft {
    var isAdmin = false
    var canDownload = true
    var canUpload = false
    var canEditMetadata = false
    var canManageLibrary = false
    var canDeleteBook = false
    var canEmailBook = false
    var canAccessOpds = true
    var canAccessBookdrop = false
    var canAccessLibraryStats = false
    var canAccessUserStats = false
    var canAccessTaskManager = false
    var canSyncKoReader = false
    var canSyncKobo = false
    var canManageMetadataConfig = false
    var canManageGlobalPreferences = false
    var canManageIcons = false
    var canManageFonts = false
    var canBulkAutoFetchMetadata = false
    var canBulkCustomFetchMetadata = false
    var canBulkEditMetadata = false
    var canBulkRegenerateCover = false
    var canMoveOrganizeFiles = false
    var canBulkLockUnlockMetadata = false
    var canBulkResetBookloreReadProgress = false
    var canBulkResetKoReaderReadProgress = false
    var canBulkResetBookReadStatus = false

    init() {}

    init(from p: GrimmoryPermissions?) {
        isAdmin = p?.isAdmin == true
        canDownload = p?.canDownload == true
        canUpload = p?.canUpload == true
        canEditMetadata = p?.canEditMetadata == true
        canManageLibrary = p?.canManageLibrary == true
        canDeleteBook = p?.canDeleteBook == true
        canEmailBook = p?.canEmailBook == true
        canAccessOpds = p?.canAccessOpds == true
        canAccessBookdrop = p?.canAccessBookdrop == true
        canAccessLibraryStats = p?.canAccessLibraryStats == true
        canAccessUserStats = p?.canAccessUserStats == true
        canAccessTaskManager = p?.canAccessTaskManager == true
        canSyncKoReader = p?.canSyncKoReader == true
        canSyncKobo = p?.canSyncKobo == true
        canManageMetadataConfig = p?.canManageMetadataConfig == true
        canManageGlobalPreferences = p?.canManageGlobalPreferences == true
        canManageIcons = p?.canManageIcons == true
        canManageFonts = p?.canManageFonts == true
        canBulkAutoFetchMetadata = p?.canBulkAutoFetchMetadata == true
        canBulkCustomFetchMetadata = p?.canBulkCustomFetchMetadata == true
        canBulkEditMetadata = p?.canBulkEditMetadata == true
        canBulkRegenerateCover = p?.canBulkRegenerateCover == true
        canMoveOrganizeFiles = p?.canMoveOrganizeFiles == true
        canBulkLockUnlockMetadata = p?.canBulkLockUnlockMetadata == true
        canBulkResetBookloreReadProgress = p?.canBulkResetBookloreReadProgress == true
        canBulkResetKoReaderReadProgress = p?.canBulkResetKoReaderReadProgress == true
        canBulkResetBookReadStatus = p?.canBulkResetBookReadStatus == true
    }

    var updatePermissions: GrimmoryUpdatePermissions {
        GrimmoryUpdatePermissions(
            isAdmin: isAdmin,
            canUpload: canUpload,
            canDownload: canDownload,
            canEditMetadata: canEditMetadata,
            canManageLibrary: canManageLibrary,
            canDeleteBook: canDeleteBook,
            canEmailBook: canEmailBook,
            canAccessOpds: canAccessOpds,
            canAccessBookdrop: canAccessBookdrop,
            canAccessLibraryStats: canAccessLibraryStats,
            canAccessUserStats: canAccessUserStats,
            canAccessTaskManager: canAccessTaskManager,
            canSyncKoReader: canSyncKoReader,
            canSyncKobo: canSyncKobo,
            canManageMetadataConfig: canManageMetadataConfig,
            canManageGlobalPreferences: canManageGlobalPreferences,
            canManageIcons: canManageIcons,
            canManageFonts: canManageFonts,
            canBulkAutoFetchMetadata: canBulkAutoFetchMetadata,
            canBulkCustomFetchMetadata: canBulkCustomFetchMetadata,
            canBulkEditMetadata: canBulkEditMetadata,
            canBulkRegenerateCover: canBulkRegenerateCover,
            canMoveOrganizeFiles: canMoveOrganizeFiles,
            canBulkLockUnlockMetadata: canBulkLockUnlockMetadata,
            canBulkResetBookloreReadProgress: canBulkResetBookloreReadProgress,
            canBulkResetKoReaderReadProgress: canBulkResetKoReaderReadProgress,
            canBulkResetBookReadStatus: canBulkResetBookReadStatus
        )
    }

    func createRequest(username: String, password: String, name: String, email: String, libraries: [Int]?) -> GrimmoryCreateUserRequest {
        GrimmoryCreateUserRequest(
            username: username,
            password: password,
            name: name,
            email: email,
            permissionAdmin: isAdmin,
            permissionUpload: canUpload,
            permissionDownload: canDownload,
            permissionEditMetadata: canEditMetadata,
            permissionManageLibrary: canManageLibrary,
            permissionDeleteBook: canDeleteBook,
            permissionEmailBook: canEmailBook,
            permissionAccessOpds: canAccessOpds,
            permissionAccessBookdrop: canAccessBookdrop,
            permissionAccessLibraryStats: canAccessLibraryStats,
            permissionAccessUserStats: canAccessUserStats,
            permissionAccessTaskManager: canAccessTaskManager,
            permissionSyncKoreader: canSyncKoReader,
            permissionSyncKobo: canSyncKobo,
            permissionManageMetadataConfig: canManageMetadataConfig,
            permissionManageGlobalPreferences: canManageGlobalPreferences,
            permissionManageIcons: canManageIcons,
            permissionManageFonts: canManageFonts,
            permissionBulkAutoFetchMetadata: canBulkAutoFetchMetadata,
            permissionBulkCustomFetchMetadata: canBulkCustomFetchMetadata,
            permissionBulkEditMetadata: canBulkEditMetadata,
            permissionBulkRegenerateCover: canBulkRegenerateCover,
            permissionMoveOrganizeFiles: canMoveOrganizeFiles,
            permissionBulkLockUnlockMetadata: canBulkLockUnlockMetadata,
            permissionBulkResetBookloreReadProgress: canBulkResetBookloreReadProgress,
            permissionBulkResetKoReaderReadProgress: canBulkResetKoReaderReadProgress,
            permissionBulkResetBookReadStatus: canBulkResetBookReadStatus,
            selectedLibraries: libraries
        )
    }
}

struct AdminGrimmoryUserSheet: View {
    let model: AdminGrimmoryModel
    let editing: GrimmoryManagedUser?

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var draft: AdminGrimmoryPermissionDraft
    @State private var selectedLibraryIds: Set<String>
    @State private var loadingAssignments = false

    init(model: AdminGrimmoryModel, editing: GrimmoryManagedUser?) {
        self.model = model
        self.editing = editing
        _draft = State(initialValue: editing.map { AdminGrimmoryPermissionDraft(from: $0.permissions) } ?? AdminGrimmoryPermissionDraft())
        _selectedLibraryIds = State(initialValue: Set((editing?.effectiveAssignedLibraries ?? []).map(String.init)))
        if let editing {
            _name = State(initialValue: editing.name ?? "")
            _email = State(initialValue: editing.email ?? "")
        }
    }

    private var adminTrimmed: (username: String, name: String, email: String) {
        (
            username.trimmingCharacters(in: .whitespacesAndNewlines),
            name.trimmingCharacters(in: .whitespacesAndNewlines),
            email.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var adminCanConfirm: Bool {
        if editing != nil { return true }
        let t = adminTrimmed
        return !t.username.isEmpty && !t.name.isEmpty && !t.email.isEmpty && password.count >= 8
    }

    var body: some View {
        AdminSheet(
            title: editing?.displayName ?? "A new account",
            confirmTitle: editing == nil ? "Create" : "Save",
            confirmDisabled: !adminCanConfirm,
            onConfirm: adminConfirm
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let editing {
                    AdminInfoRow(label: "Username", value: editing.username ?? "-")
                } else {
                    SourcesField(label: "Username", text: $username)
                }
                SourcesField(label: "Display name", text: $name)
                SourcesField(label: "Email", text: $email, keyboard: .emailAddress)
                if editing == nil {
                    SourcesField(label: "Password (eight characters at least)", text: $password, secure: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Overline("Role")
                SourcesToggleRow(title: "Administrator", isOn: $draft.isAdmin)
            }

            VStack(alignment: .leading, spacing: 10) {
                Overline("Core permissions")
                SourcesToggleRow(title: "Download books", isOn: $draft.canDownload)
                SourcesToggleRow(title: "Upload books", isOn: $draft.canUpload)
                SourcesToggleRow(title: "Edit metadata", isOn: $draft.canEditMetadata)
                SourcesToggleRow(title: "Manage libraries", isOn: $draft.canManageLibrary)
                SourcesToggleRow(title: "Delete books", isOn: $draft.canDeleteBook)
                SourcesToggleRow(title: "Email books", isOn: $draft.canEmailBook)
            }

            VStack(alignment: .leading, spacing: 10) {
                Overline("Access")
                SourcesToggleRow(title: "OPDS", isOn: $draft.canAccessOpds)
                SourcesToggleRow(title: "Bookdrop", isOn: $draft.canAccessBookdrop)
                SourcesToggleRow(title: "Library statistics", isOn: $draft.canAccessLibraryStats)
                SourcesToggleRow(title: "User statistics", isOn: $draft.canAccessUserStats)
                SourcesToggleRow(title: "Task manager", isOn: $draft.canAccessTaskManager)
            }

            VStack(alignment: .leading, spacing: 10) {
                Overline("Sync")
                SourcesToggleRow(title: "KOReader sync", isOn: $draft.canSyncKoReader)
                SourcesToggleRow(title: "Kobo sync", isOn: $draft.canSyncKobo)
            }

            VStack(alignment: .leading, spacing: 10) {
                Overline("Management")
                SourcesToggleRow(title: "Metadata configuration", isOn: $draft.canManageMetadataConfig)
                SourcesToggleRow(title: "Global preferences", isOn: $draft.canManageGlobalPreferences)
                SourcesToggleRow(title: "Icons", isOn: $draft.canManageIcons)
                SourcesToggleRow(title: "Fonts", isOn: $draft.canManageFonts)
            }

            VStack(alignment: .leading, spacing: 10) {
                Overline("Bulk operations")
                SourcesToggleRow(title: "Auto-fetch metadata", isOn: $draft.canBulkAutoFetchMetadata)
                SourcesToggleRow(title: "Custom-fetch metadata", isOn: $draft.canBulkCustomFetchMetadata)
                SourcesToggleRow(title: "Bulk edit metadata", isOn: $draft.canBulkEditMetadata)
                SourcesToggleRow(title: "Regenerate covers", isOn: $draft.canBulkRegenerateCover)
                SourcesToggleRow(title: "Move & organize files", isOn: $draft.canMoveOrganizeFiles)
                SourcesToggleRow(title: "Lock & unlock metadata", isOn: $draft.canBulkLockUnlockMetadata)
                SourcesToggleRow(title: "Reset Grimmory progress", isOn: $draft.canBulkResetBookloreReadProgress)
                SourcesToggleRow(title: "Reset KOReader progress", isOn: $draft.canBulkResetKoReaderReadProgress)
                SourcesToggleRow(title: "Reset read status", isOn: $draft.canBulkResetBookReadStatus)
            }

            if !model.libraries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Overline("Library access")
                    if loadingAssignments {
                        AdminLoadingRow("Fetching the current assignments…")
                    }
                    Text(
                        editing == nil
                            ? "Choose the libraries this account may enter. Leave them all off for everything."
                            : "Choose the full set of libraries this account may enter."
                    )
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    ForEach(model.libraries) { library in
                        SourcesToggleRow(
                            title: library.name,
                            isOn: Binding(
                                get: { selectedLibraryIds.contains(library.id) },
                                set: { isOn in
                                    if isOn { selectedLibraryIds.insert(library.id) } else { selectedLibraryIds.remove(library.id) }
                                }
                            )
                        )
                    }
                }
            }
        }
        .task {

            guard let editing, editing.effectiveAssignedLibraries == nil else { return }
            loadingAssignments = true
            if let detailed = try? await model.fetchUser(id: editing.id) {
                selectedLibraryIds = Set((detailed.effectiveAssignedLibraries ?? []).map(String.init))
            }
            loadingAssignments = false
        }
    }

    private func adminConfirm() {
        let t = adminTrimmed
        if let editing {
            let assignedLibraries = selectedLibraryIds.compactMap { Int($0) }.sorted()
            if !draft.isAdmin && assignedLibraries.isEmpty {
                model.error = "A non-administrator account needs at least one library."
                return
            }

            let request = GrimmoryUpdateUserRequest(
                name: t.name.isEmpty ? editing.name : t.name,
                email: t.email.isEmpty ? editing.email : t.email,
                permissions: draft.updatePermissions,
                assignedLibraries: assignedLibraries
            )
            Task {
                model.error = nil
                model.successMessage = nil
                await model.updateUser(id: editing.id, request: request)
                if model.error == nil { dismiss() }
            }
        } else {
            let libraries = selectedLibraryIds.isEmpty ? nil : selectedLibraryIds.compactMap { Int($0) }
            let request = draft.createRequest(
                username: t.username,
                password: password,
                name: t.name,
                email: t.email,
                libraries: libraries
            )
            Task {
                model.error = nil
                model.successMessage = nil
                await model.createUser(request)
                if model.error == nil { dismiss() }
            }
        }
    }
}

struct AdminGrimmoryPasswordSheet: View {
    let model: AdminGrimmoryModel
    let user: GrimmoryManagedUser

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    var body: some View {
        AdminSheet(
            title: "A new password",
            confirmTitle: "Save",
            confirmDisabled: newPassword.count < 8 || newPassword != confirmPassword,
            onConfirm: {
                Task {
                    await model.changeUserPassword(userId: user.id, newPassword: newPassword)
                }
                dismiss()
            }
        ) {
            Text("For \(user.displayName). Eight characters at least.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
            SourcesField(label: "New password", text: $newPassword, secure: true)
            SourcesField(label: "Once more", text: $confirmPassword, secure: true)
            if !newPassword.isEmpty, !confirmPassword.isEmpty, newPassword != confirmPassword {
                Text("The two passwords do not match.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusError)
            }
        }
    }
}
