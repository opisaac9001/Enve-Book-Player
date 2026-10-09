import SwiftUI

struct ProfilesScreen: View {
    @Environment(ProfileSwitchCoordinator.self) private var profiles
    @Environment(\.hearth) private var hearth
    @State private var editor: ProfileEditorAction?
    @State private var pendingProfileID: String?
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var needsAuthorization: Bool {
        profiles.isParentAuthorizationRequired && !profiles.isParentAuthorized
    }

    var body: some View {
        SettingsScaffold(overline: "On this device", title: "Profiles", subtitle: "Separate libraries, settings and reading positions for each person.") {
            if !profiles.isEnabled {
                Text("Your current library becomes the first adult profile. Books already on this device stay available.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                EmberButton(title: "Set up profiles", systemImage: "person.crop.circle.badge.plus") {
                    editor = .enable
                }
                .accessibilityIdentifier("profiles-enable")
            } else {
                SourcesCard {
                    ForEach(profiles.profiles) { profile in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: profile.role == .child ? "figure.child" : "person.crop.circle")
                                    .foregroundStyle(hearth.ember)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name).font(.hearthBody.weight(.semibold))
                                    Text(profile.role == .child ? "Child" : "Adult")
                                        .font(.hearthCaption).foregroundStyle(hearth.textSecondary)
                                }
                                Spacer()
                                if profile.id == profiles.activeProfile.id {
                                    Text("Current").font(.hearthCaption).foregroundStyle(hearth.ember)
                                        .accessibilityIdentifier("profile-current-\(profile.id)")
                                }
                            }
                            QuietButton(title: "Use \(profile.name)") {
                                if profile.role == .adult && needsAuthorization {
                                    pendingProfileID = profile.id
                                    editor = .unlock
                                } else {
                                    perform { try await profiles.switchProfile(id: profile.id) }
                                }
                            }
                            .accessibilityIdentifier("profile-switch-\(profile.id)")
                            if !needsAuthorization {
                                Toggle("Server syncing", isOn: Binding(
                                    get: { profiles.serverSyncEnabled(profileID: profile.id) },
                                    set: { enabled in perform { try profiles.setServerSyncEnabled(enabled, profileID: profile.id) } }
                                ))
                                .accessibilityIdentifier("profile-server-sync-\(profile.id)")
                                Text("Sync reading and listening progress with this person's server account. Leave off if they share a login and need separate progress.")
                                    .font(.hearthCaption).foregroundStyle(hearth.textSecondary)
                                HStack {
                                    Button("Rename") { editor = .rename(profile) }
                                    Spacer()
                                    if profile.id != FamilyProfile.ownerID {
                                        Button("Remove", role: .destructive) { editor = .remove(profile) }
                                    }
                                }
                                .font(.hearthCaption)
                                NavigationLink {
                                    ProfileDownloadImportScreen(destination: profile)
                                } label: {
                                    SettingsLinkRow(title: "Import downloaded books", systemImage: "square.and.arrow.down")
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                if needsAuthorization {
                    EmberButton(title: "Adult controls", systemImage: "lock") { editor = .unlock }
                        .accessibilityIdentifier("profiles-unlock")
                } else {
                    EmberButton(title: "Add profile", systemImage: "person.badge.plus") { editor = .add }
                        .accessibilityIdentifier("profiles-add")
                    QuietButton(title: profiles.hasPIN ? "Change adult PIN" : "Set adult PIN", systemImage: "lock") { editor = .pin }
                    if profiles.profiles.count == 1 {
                        QuietButton(title: "Turn off profiles") { perform { try profiles.disable() } }
                    }
                }
            }
            if isWorking || profiles.isSwitching { ProgressView() }
            if let message = errorMessage ?? profiles.errorMessage {
                Text(message).font(.hearthCaption).foregroundStyle(hearth.statusError)
            }
        }
        .disabled(isWorking || profiles.isSwitching)
        .sheet(item: $editor, onDismiss: {
            guard let id = pendingProfileID else { return }
            pendingProfileID = nil
            if profiles.isParentAuthorized {
                perform { try await profiles.switchProfile(id: id) }
            }
        }) { action in
            ProfileEditorSheet(action: action)
        }
        .accessibilityIdentifier("profiles-screen")
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do { try await action() }
            catch { errorMessage = "That change could not be saved. Please try again." }
        }
    }
}

private enum ProfileEditorAction: Identifiable {
    case enable, add, unlock, pin
    case rename(FamilyProfile), remove(FamilyProfile)

    var id: String {
        switch self {
        case .enable: "enable"
        case .add: "add"
        case .unlock: "unlock"
        case .pin: "pin"
        case .rename(let profile): "rename-\(profile.id)"
        case .remove(let profile): "remove-\(profile.id)"
        }
    }

    var title: String {
        switch self {
        case .enable: "Set up profiles"
        case .add: "Add profile"
        case .unlock: "Adult controls"
        case .pin: "Adult PIN"
        case .rename: "Rename profile"
        case .remove(let profile): "Remove \(profile.name)?"
        }
    }
}

private struct ProfileEditorSheet: View {
    let action: ProfileEditorAction
    @Environment(ProfileSwitchCoordinator.self) private var profiles
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hearth) private var hearth
    @State private var name = ""
    @State private var isChild = false
    @State private var serverSyncEnabled = false
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var currentPIN = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                switch action {
                case .enable:
                    TextField("Your name", text: $name).accessibilityIdentifier("profile-name")
                    Text("An adult PIN is optional until you add a child profile.")
                    newPINFields
                case .add:
                    TextField("Name", text: $name).accessibilityIdentifier("profile-name")
                    Toggle("Do you want to turn on syncing?", isOn: $serverSyncEnabled)
                        .accessibilityIdentifier("profile-setup-server-sync")
                    Text("Turn on to continue reading and listening across devices using this person's server account. Leave off to keep their progress separate when sharing a server login with someone else.")
                    Toggle("Child profile", isOn: $isChild)
                    if isChild && !profiles.hasPIN {
                        Text("Set an adult PIN to protect adult profiles and profile management.")
                        newPINFields
                    }
                case .unlock:
                    SecureField("Adult PIN", text: $pin).keyboardType(.numberPad)
                        .accessibilityIdentifier("profile-pin")
                case .pin:
                    if profiles.hasPIN {
                        SecureField("Current PIN", text: $currentPIN).keyboardType(.numberPad)
                    }
                    newPINFields
                    if profiles.hasPIN {
                        Button("Forgot PIN? Verify this device") { save(resetPIN: true) }
                            .disabled(pin.isEmpty || pin != confirmation)
                    }
                case .rename:
                    TextField("Name", text: $name).accessibilityIdentifier("profile-name")
                case .remove:
                    Text("This removes this person's library and positions from this device. Books used by other profiles stay available.")
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(hearth.statusError) }
                if isWorking { ProgressView() }
            }
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isRemoval ? "Remove" : "Save") { save() }
                        .disabled(isWorking)
                        .accessibilityIdentifier("profile-save")
                }
            }
            .disabled(isWorking)
        }
        .interactiveDismissDisabled(isWorking)
        .onAppear {
            if case .rename(let profile) = action { name = profile.name }
        }
    }

    private var isRemoval: Bool {
        if case .remove = action { true } else { false }
    }

    private var newPINFields: some View {
        Group {
            SecureField("New PIN", text: $pin).keyboardType(.numberPad)
                .accessibilityIdentifier("profile-pin")
            SecureField("Confirm PIN", text: $confirmation).keyboardType(.numberPad)
                .accessibilityIdentifier("profile-pin-confirm")
        }
    }

    private func save(resetPIN: Bool = false) {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                if resetPIN {
                    guard pin == confirmation else { throw FamilyProfileError.invalidName }
                    try await profiles.resetPIN(newPIN: pin)
                } else {
                    switch action {
                    case .enable:
                        guard pin == confirmation else { throw FamilyProfileError.invalidName }
                        try profiles.enable(ownerName: name, pin: pin.isEmpty ? nil : pin)
                    case .add:
                        if isChild && !profiles.hasPIN {
                            guard pin == confirmation else { throw FamilyProfileError.invalidName }
                            try profiles.configurePIN(pin)
                        }
                        _ = try profiles.addProfile(name: name, role: isChild ? .child : .adult, serverSyncEnabled: serverSyncEnabled)
                    case .unlock:
                        try profiles.authorizeParent(pin: pin)
                    case .pin:
                        guard pin == confirmation else { throw FamilyProfileError.invalidName }
                        if profiles.hasPIN { try profiles.changePIN(currentPIN: currentPIN, newPIN: pin) }
                        else { try profiles.configurePIN(pin) }
                    case .rename(let profile): try profiles.renameProfile(id: profile.id, name: name)
                    case .remove(let profile): try await profiles.removeProfile(id: profile.id)
                    }
                }
                dismiss()
            } catch {
                errorMessage = "Check the name and PIN, then try again. Too many incorrect PIN attempts temporarily lock adult controls."
            }
        }
    }
}
