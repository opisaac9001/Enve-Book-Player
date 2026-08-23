import SwiftUI

struct HardcoverScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var connectedUsername: String?
    @State private var syncStats: (started: Int, completed: Int)?
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var confirmDisconnect = false

    private var isConnected: Bool {
        SettingsManager.shared.hardcoverApiKey != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
                    VStack(alignment: .leading, spacing: 6) {
                        Overline("Sync")
                        Text("Hardcover")
                            .font(.hearthScreenTitle)
                            .foregroundStyle(hearth.text)
                        Text("Your reading life, kept on your Hardcover shelves too.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                    }
                    Spacer(minLength: 0)
                }

                if isConnected {
                    connectedCard
                } else {
                    connectCard
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                if let errorMessage { SourcesErrorText(message: errorMessage) }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .alert("Disconnect Hardcover?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) {
                disconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved API key and clears Hardcover sync tracking on this device.")
        }
        .task {
            guard isConnected else { return }
            syncStats = await HardcoverSyncService.shared.getSyncStats()
            if connectedUsername == nil {
                connectedUsername = try? await HardcoverService.shared.getCurrentUser().username
            }
        }
    }

    private var connectedCard: some View {
        SourcesCard {
            HStack(spacing: 10) {
                Circle().fill(hearth.statusOK).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectedUsername.map { "@\($0)" } ?? "Connected")
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                    if let syncStats {
                        Text("\(syncStats.started) started · \(syncStats.completed) finished")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
            }

            QuietButton(title: "Disconnect Hardcover", systemImage: "xmark.circle") {
                confirmDisconnect = true
            }
        }
    }

    private var connectCard: some View {
        SourcesCard {
            SourcesField(label: "API key", text: $apiKey, placeholder: "From hardcover.app settings", secure: true)
            Text("Find your key under Settings > API on hardcover.app.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)

            EmberButton(title: isWorking ? "Checking…" : "Connect", systemImage: nil, tint: nil) {
                connect()
            }
            .disabled(isWorking || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(isWorking || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
        }
    }

    private func connect() {
        let stripped = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = nil

        Task {
            SettingsManager.shared.hardcoverApiKey = stripped
            do {
                let user = try await HardcoverService.shared.getCurrentUser()
                connectedUsername = user.username
                statusMessage = "Connected as @\(user.username)."
                PlatformHaptics.notification(.success)
            } catch {
                let isAuthFailure =
                    switch error as? HardcoverError {
                    case .httpError(let statusCode, let message):
                        HardcoverError.isAuthenticationFailure(statusCode: statusCode, message: message)
                    case .graphQLError(let message):
                        HardcoverError.isAuthenticationFailure(statusCode: 200, message: message)
                    default:
                        false
                    }
                if isAuthFailure {
                    SettingsManager.shared.clearHardcoverAccess(reason: "authenticationFailed")
                    errorMessage = "Hardcover didn't accept that key."
                } else {
                    errorMessage = "Couldn't verify the key: \(error.localizedDescription)"
                }
            }
            isWorking = false
        }
    }

    private func disconnect() {
        SettingsManager.shared.clearHardcoverAccess(reason: "userDisconnected")
        Task { await HardcoverSyncService.shared.clearSyncTracking() }
        connectedUsername = nil
        syncStats = nil
        apiKey = ""
        statusMessage = "Disconnected."
        PlatformHaptics.notification(.success)
    }
}
