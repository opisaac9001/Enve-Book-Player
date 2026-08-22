import SwiftUI

struct AdminABSUsersScreen: View {
    let model: AdminABSModel

    @Environment(\.hearth) private var hearth
    @State private var showingAddUser = false
    @State private var editingUser: ABSUser?

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Users & sessions") {
            SourcesCard {
                Overline("Listening now")
                if model.activeSessions.isEmpty {
                    AdminEmptyText("No one is listening right now.")
                } else {
                    ForEach(Array(model.activeSessions.enumerated()), id: \.offset) { _, session in
                        adminSessionRow(session)
                    }
                }
            }

            SourcesCard {
                HStack {
                    Overline("Accounts")
                    Spacer()
                    GlyphButton(systemImage: "person.badge.plus", size: 40, glyphSize: 15, label: "Add a user") {
                        showingAddUser = true
                    }
                }
                if model.users.isEmpty {
                    AdminEmptyText(model.isLoading ? "Fetching the accounts…" : "No accounts to show.")
                } else {
                    ForEach(model.users) { user in
                        adminUserRow(user)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddUser) {
            AdminABSAddUserSheet(model: model)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .sheet(item: $editingUser) { user in
            AdminABSEditUserSheet(model: model, user: user)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
    }

    private func adminSessionRow(_ session: ABSPlaySession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.displayTitle ?? "Untitled")
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                Spacer()
                if let client = session.deviceInfo?.clientName {
                    AdminTag(text: client)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(session.displayAuthor ?? "Unknown author")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(1)
                Spacer()
                if let current = session.currentTime, let duration = session.duration {
                    Text("\(HearthFormat.clock(current)) of \(HearthFormat.clock(duration))")
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.textTertiary)
                        .monospacedDigit()
                }
            }
            if let current = session.currentTime, let duration = session.duration, duration > 0 {
                AdminProgressLine(fraction: current / duration)
            }
        }
        .padding(.vertical, 4)
    }

    private func adminUserRow(_ user: ABSUser) -> some View {
        Button {
            editingUser = user
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.username)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    Text(user.type.capitalized)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
                if user.isActive == false || user.isLocked == true {
                    Image(systemName: "lock.fill")
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.statusError)
                }
                Image(systemName: "chevron.right")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct AdminABSAddUserSheet: View {
    let model: AdminABSModel

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var type = "user"

    var body: some View {
        AdminSheet(
            title: "A new account",
            confirmTitle: "Create",
            confirmDisabled: username.isEmpty || password.isEmpty,
            onConfirm: {
                Task {
                    await model.createUser(
                        ABSUserCreateRequest(
                            username: username,
                            password: password,
                            type: type,
                            permissions: nil
                        )
                    )
                    dismiss()
                }
            }
        ) {
            SourcesField(label: "Username", text: $username)
            SourcesField(label: "Password", text: $password, secure: true)
            VStack(alignment: .leading, spacing: 7) {
                Overline("Account type")
                HStack(spacing: 8) {
                    ForEach(["user", "admin", "guest"], id: \.self) { option in
                        HearthChip(title: option.capitalized, isSelected: type == option) {
                            type = option
                        }
                    }
                }
            }
        }
    }
}

private struct AdminABSEditUserSheet: View {
    let model: AdminABSModel
    let user: ABSUser

    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var type: String
    @State private var confirmingDelete = false

    init(model: AdminABSModel, user: ABSUser) {
        self.model = model
        self.user = user
        _username = State(initialValue: user.username)
        _type = State(initialValue: user.type)
    }

    var body: some View {
        AdminSheet(
            title: user.username,
            confirmTitle: "Save",
            onConfirm: {
                Task {
                    await model.updateUser(
                        id: user.id,
                        request: ABSUserUpdateRequest(
                            username: username,
                            type: type,
                            permissions: nil,
                            librariesAccessible: nil
                        )
                    )
                    dismiss()
                }
            }
        ) {
            SourcesField(label: "Username", text: $username)
            VStack(alignment: .leading, spacing: 7) {
                Overline("Account type")
                HStack(spacing: 8) {
                    ForEach(["user", "admin", "root", "guest"], id: \.self) { option in
                        HearthChip(title: option.capitalized, isSelected: type == option) {
                            type = option
                        }
                    }
                }
            }
            AdminDestructiveButton(title: "Delete this account", systemImage: "trash") {
                confirmingDelete = true
            }
        }
        .alert("Delete this account", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.deleteUser(id: user.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(user.username) will be removed from the server. There is no undoing this.")
        }
    }
}
