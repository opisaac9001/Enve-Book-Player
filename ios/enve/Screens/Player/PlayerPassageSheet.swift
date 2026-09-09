import SwiftUI

@available(iOS 26.0, *)
struct PlayerPassageSheet: View {
    let ebook: Book
    let audiobook: Book
    let position: TimeInterval

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var match: LinkedBookSparseMatcher.Match?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Find this passage")
                        .font(.hearthDisplay(24, weight: .semibold))
                    Spacer()
                    Button("Close") { dismiss() }
                }
                Text("Apple on-device transcription · No audio is uploaded")
                    .font(.hearthUI(13))
                    .foregroundStyle(hearth.textSecondary)
                if let match {
                    Text(ebook.title).font(.hearthUI(16, weight: .semibold))
                    Text(match.quote).font(.hearthDisplay(20))
                        .textSelection(.enabled)
                    Text("A matching passage near your paused position. Open it only if this looks right.")
                        .font(.hearthUI(14))
                        .foregroundStyle(hearth.textSecondary)
                    Button("Open passage in ebook") {
                        do {
                            let target = try LinkedBookPassageService.bookForOpening(ebook, match: match)
                            dismiss()
                            engine.playback.presentReaderAfterDismissingPlayer(for: target)
                        } catch {
                            failure = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Hearth.accent)
                    .disabled(engine.playback.currentBook?.stableId != audiobook.stableId)
                } else if let failure {
                    Text(failure).font(.hearthUI(16))
                } else {
                    ProgressView("Finding a matching passage…")
                    Text("Reading a short audio sample using the same Apple speech system as Quick Sync.")
                        .font(.hearthUI(14))
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            .foregroundStyle(hearth.text)
            .padding(24)
        }
        .task {
            do {
                let result = try await LinkedBookPassageService.find(ebook: ebook, audiobook: audiobook, at: position)
                try Task.checkCancellation()
                match = result
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }
}
