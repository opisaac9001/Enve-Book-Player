import SwiftUI

struct ProfileDownloadImportScreen: View {
    let destination: FamilyProfile
    @Environment(ProfileSwitchCoordinator.self) private var profiles
    @Environment(\.hearth) private var hearth
    @State private var sourceID: String?
    @State private var candidates: [ProfileDownloadImportCandidate] = []
    @State private var isWorking = false
    @State private var message: String?

    private var permitted: Bool { !profiles.isParentAuthorizationRequired || profiles.isParentAuthorized }

    var body: some View {
        SettingsScaffold(overline: "On this device", title: "Import downloaded books", subtitle: "For \(destination.name). Files are reused; reading and listening start with a separate position.") {
            if permitted {
                SourcesCard {
                    ForEach(profiles.profiles.filter { $0.id != destination.id }) { source in
                        Button { load(source.id) } label: {
                            SettingsLinkRow(title: "Choose from \(source.name)", systemImage: "person.crop.circle")
                        }
                    }
                }
                if sourceID != nil && candidates.isEmpty && !isWorking {
                    Text("No completed downloads are available from this profile.")
                        .font(.hearthBody).foregroundStyle(hearth.textSecondary)
                }
                ForEach(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(candidate.sourceBook.title).font(.hearthBody.weight(.semibold)).foregroundStyle(hearth.text)
                        QuietButton(title: "Import", systemImage: "square.and.arrow.down") { importBook(candidate) }
                    }
                }
            } else {
                Text("Unlock adult controls to choose books from another profile.")
                    .font(.hearthBody).foregroundStyle(hearth.textSecondary)
            }
            if isWorking { ProgressView() }
            if let message { Text(message).font(.hearthCaption).foregroundStyle(hearth.textSecondary) }
        }
        .disabled(isWorking)
        .onChange(of: profiles.isParentAuthorized) { _, _ in
            if !permitted { sourceID = nil; candidates = []; message = nil }
        }
        .accessibilityIdentifier("profile-download-import")
    }

    private func load(_ profileID: String) {
        sourceID = profileID
        candidates = []
        message = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let loaded = try await profiles.importCandidates(from: profileID)
                if permitted && sourceID == profileID { candidates = loaded }
            } catch { message = "Couldn't load completed downloads. Please try again." }
        }
    }

    private func importBook(_ candidate: ProfileDownloadImportCandidate) {
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                _ = try await profiles.importCompleted(candidate, into: destination.id)
                message = "Added to \(destination.name)'s library."
            } catch { message = "Couldn't import this download. The original book is unchanged." }
        }
    }
}
