#if os(iOS)
import SwiftUI

struct ReadwiseScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.profileSession) private var profileSession

    @State private var token = ""
    @State private var confirmDisconnect = false

    private static let accessTokenURL = URL(string: "https://readwise.io/access_token")!

    private var readwise: ReadwiseExportService { (profileSession ?? .owner).readwise }

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsScaffold(
            overline: "Export",
            title: "Readwise",
            subtitle: "Send a book's highlights to your Readwise account."
        ) {
            SourcesCard {
                Text("Enve only sends to Readwise. Highlights go when you tap Send in a book's Export sheet in the Reader; nothing is sent automatically.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Enve never imports highlights from Readwise and never deletes anything there.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if readwise.isConnected {
                connectedCard
            } else {
                connectCard
            }

            if readwise.isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(hearth.ember)
                    QuietButton(title: "Cancel", systemImage: "xmark") {
                        readwise.cancel()
                    }
                }
            }

            if let statusMessage = readwise.statusMessage, readwise.lastError == nil {
                Text(statusMessage)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = readwise.lastError {
                SourcesErrorText(message: error)
            }
        }
        .alert("Disconnect Readwise?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) {
                readwise.disconnect()
                if !readwise.isConnected { PlatformHaptics.notification(.success) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved token and this profile's Readwise export history on this device. Highlights already in Readwise stay there.")
        }
    }

    private var connectedCard: some View {
        SourcesCard {
            HStack(spacing: 10) {
                Circle().fill(hearth.statusOK).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected")
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                    Text(lastSentDescription)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)

            QuietButton(title: "Disconnect Readwise", systemImage: "xmark.circle") {
                confirmDisconnect = true
            }
            .disabled(readwise.isWorking)
            .opacity(readwise.isWorking ? 0.5 : 1)
        }
    }

    private var lastSentDescription: String {
        guard let lastSentAt = readwise.lastSentAt else { return "Nothing sent yet" }
        return "Last sent \(lastSentAt.formatted(.relative(presentation: .named)))"
    }

    private var connectCard: some View {
        SourcesCard {
            SourcesField(
                label: "Access token",
                text: $token,
                placeholder: "Paste your Readwise token",
                secure: true,
                disabled: readwise.isWorking
            )
            Link(destination: Self.accessTokenURL) {
                Label("Get your token at readwise.io/access_token", systemImage: "arrow.up.right.square")
                    .font(.hearthCaption.weight(.medium))
                    .foregroundStyle(hearth.ember)
            }

            EmberButton(title: readwise.isWorking ? "Checking…" : "Connect", systemImage: nil, tint: nil) {
                connect()
            }
            .disabled(readwise.isWorking || trimmedToken.isEmpty)
            .opacity(readwise.isWorking || trimmedToken.isEmpty ? 0.5 : 1)
        }
    }

    private func connect() {
        let candidate = trimmedToken
        guard !candidate.isEmpty else { return }
        Task {
            await readwise.connect(token: candidate)
            if readwise.isConnected, readwise.lastError == nil {
                token = ""
                PlatformHaptics.notification(.success)
            }
        }
    }
}
#endif
