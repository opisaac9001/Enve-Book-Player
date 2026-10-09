import SwiftUI

struct ProfilePickerScreen: View {
    @Environment(ProfileSwitchCoordinator.self) private var profiles
    @Environment(\.hearth) private var hearth
    @State private var selectedAdult: FamilyProfile?
    @State private var pin = ""
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Overline("On this device")
                Text("Who's reading?").font(.hearthScreenTitle).foregroundStyle(hearth.text)
                Text("Choose a profile to continue.").font(.hearthBody).foregroundStyle(hearth.textSecondary)
                ForEach(profiles.profiles) { profile in
                    QuietButton(title: profile.name, systemImage: profile.role == .child ? "figure.child" : "person.crop.circle") {
                        if profile.role == .adult && profiles.isParentAuthorizationRequired && !profiles.isParentAuthorized {
                            selectedAdult = profile
                        } else { choose(profile) }
                    }
                    .accessibilityIdentifier("profile-picker-\(profile.id)")
                }
                if profiles.isSwitching { ProgressView() }
                if let message = errorMessage ?? profiles.errorMessage { Text(message).foregroundStyle(hearth.statusError) }
            }
            .padding(24)
        }
        .background(HearthBackground())
        .disabled(profiles.isSwitching)
        .sheet(item: $selectedAdult, onDismiss: { pin = "" }) { profile in
            NavigationStack {
                Form {
                    SecureField("Adult PIN", text: $pin).keyboardType(.numberPad)
                        .accessibilityIdentifier("profile-pin")
                    if let errorMessage { Text(errorMessage).foregroundStyle(hearth.statusError) }
                    Button("Unlock") {
                        do {
                            try profiles.authorizeParent(pin: pin)
                            pin = ""
                            selectedAdult = nil
                            choose(profile)
                        } catch {
                            pin = ""
                            errorMessage = "Incorrect PIN or adult controls are temporarily locked. Try again later."
                        }
                    }
                    .accessibilityIdentifier("profile-unlock")
                }
                .navigationTitle("Open \(profile.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { selectedAdult = nil } } }
            }
        }
        .accessibilityIdentifier("profile-picker")
    }

    private func choose(_ profile: FamilyProfile) {
        errorMessage = nil
        Task {
            do { try await profiles.switchProfile(id: profile.id) }
            catch { errorMessage = "Unable to open this profile. Please try again." }
        }
    }
}
