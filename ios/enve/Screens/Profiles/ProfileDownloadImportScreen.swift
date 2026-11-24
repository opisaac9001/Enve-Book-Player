import SwiftUI

struct ProfileDownloadImportScreen: View {
    let destination: FamilyProfile
    @Environment(ProfileSwitchCoordinator.self) private var profiles
    @Environment(\.hearth) private var hearth
    @State private var request: CandidateRequest?
    @State private var candidates: CandidateState = .idle
    @State private var importingID: String?
    @State private var message: String?

    private var permitted: Bool { !profiles.isParentAuthorizationRequired || profiles.isParentAuthorized }

    private var isBusy: Bool {
        if case .loading = candidates { return true }
        return importingID != nil
    }

    var body: some View {
        SettingsScaffold(overline: "On this device", title: "Import downloaded books", subtitle: "For \(destination.name). Files are reused; reading and listening start with a separate position.") {
            if permitted {
                SourcesCard {
                    ForEach(profiles.profiles.filter { $0.id != destination.id }) { source in
                        Button { load(source.id) } label: {
                            SettingsLinkRow(title: "Choose from \(source.name)", systemImage: "person.crop.circle")
                        }
                        .disabled(isBusy)
                        .accessibilityIdentifier("profile-download-import-source-\(source.id)")
                    }
                }
                switch candidates {
                case .idle:
                    EmptyView()
                case .loading:
                    ProgressView()
                case .failed:
                    Text("Couldn't load completed downloads. Please try again.")
                        .font(.hearthBody).foregroundStyle(hearth.textSecondary)
                case .loaded(let loaded) where loaded.isEmpty:
                    Text("No completed downloads are available from this profile.")
                        .font(.hearthBody).foregroundStyle(hearth.textSecondary)
                case .loaded(let loaded):
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(loaded) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
            } else {
                Text("Unlock adult controls to choose books from another profile.")
                    .font(.hearthBody).foregroundStyle(hearth.textSecondary)
            }
            if let message { Text(message).font(.hearthCaption).foregroundStyle(hearth.textSecondary) }
        }
        .task(id: request) {
            guard let request, case .loading = candidates else { return }
            do {
                let loaded = try await profiles.importCandidates(from: request.sourceID)
                try Task.checkCancellation()
                guard self.request == request, permitted else { return }
                candidates = .loaded(loaded)
            } catch {
                guard !Task.isCancelled, self.request == request, permitted else { return }
                candidates = .failed
            }
        }
        .onChange(of: profiles.isParentAuthorized) { _, _ in
            if !permitted { request = nil; candidates = .idle; message = nil }
        }
        .accessibilityIdentifier("profile-download-import")
    }

    private func candidateRow(_ candidate: ProfileDownloadImportCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(candidate.sourceBook.title).font(.hearthBody.weight(.semibold)).foregroundStyle(hearth.text)
            HStack(spacing: 12) {
                QuietButton(title: "Import", systemImage: "square.and.arrow.down") { importBook(candidate) }
                    .disabled(importingID != nil)
                    .accessibilityLabel("Import \(candidate.sourceBook.title)")
                    .accessibilityIdentifier("profile-download-import-book-\(candidate.id)")
                if importingID == candidate.id { ProgressView() }
            }
        }
    }

    private func load(_ profileID: String) {
        request = CandidateRequest(sourceID: profileID)
        candidates = .loading
        message = nil
    }

    private func importBook(_ candidate: ProfileDownloadImportCandidate) {
        guard importingID == nil else { return }
        importingID = candidate.id
        message = nil
        // Deliberately unstructured: leaving the screen must not cancel the import transaction midway.
        Task {
            defer { importingID = nil }
            do {
                _ = try await profiles.importCompleted(candidate, into: destination.id)
                message = "Added to \(destination.name)'s library."
            } catch { message = "Couldn't import this download. The original book is unchanged." }
        }
    }
}

private struct CandidateRequest: Equatable {
    let sourceID: String
    let id = UUID()
}

private enum CandidateState {
    case idle
    case loading
    case loaded([ProfileDownloadImportCandidate])
    case failed
}
