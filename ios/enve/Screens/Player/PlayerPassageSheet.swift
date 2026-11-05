import SwiftUI

struct PlayerPassageSheet: View {
    let ebook: Book
    let audiobook: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.profileSession) private var capturedSession
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var match: PassageMapping?
    @State private var failure: String?

    private var profileSession: ProfileSession { capturedSession ?? .owner }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Find this passage")
                        .font(.hearthDisplay(24, weight: .semibold))
                    Spacer()
                    Button("Close") { dismiss() }
                }
                Text("On-device alignment · No audio is uploaded")
                    .font(.hearthUI(13))
                    .foregroundStyle(hearth.textSecondary)
                if let match {
                    Text(ebook.title).font(.hearthUI(16, weight: .semibold))
                    Text(match.text).font(.hearthDisplay(20))
                        .textSelection(.enabled)
                    Text("The sentence being narrated now. Open it only if this looks right.")
                        .font(.hearthUI(14))
                        .foregroundStyle(hearth.textSecondary)
                    Button("Open passage in ebook") {
                        dismiss()
                        engine.playback.presentReaderAfterDismissingPlayer(for: ebook, at: match.locatorJSON)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Hearth.accent)
                    .disabled(engine.playback.currentBook?.stableId != audiobook.stableId)
                } else if let failure {
                    Text(failure).font(.hearthUI(16))
                    Button("Open approximate position") {
                        dismiss()
                        engine.playback.presentReaderAfterDismissingPlayer(for: ebook)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Opens the ebook at its estimated position, which may not be the exact sentence.")
                } else {
                    ProgressView("Finding the narrated sentence…")
                    Text("Prepared passages open immediately. Otherwise Enve analyzes a short stretch around the narration for up to 30 seconds.")
                        .font(.hearthUI(14))
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            .foregroundStyle(hearth.text)
            .padding(24)
        }
        .task {
            let controller = profileSession.playback.composition.controller
            do {
                let result = try await LinkedBookPassageService.find(
                    ebook: ebook, audiobook: audiobook, profileSession: profileSession, playhead: { controller.progress }
                )
                try Task.checkCancellation()
                match = result
            } catch is CancellationError {
                profileSession.passageAlignment.cancelExplicitRequests()
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }
}
