import SwiftUI

struct SourcesCloudScreen: View {
    enum Drive: String, Identifiable {
        case googleDrive, dropbox, icloud

        var id: String { rawValue }

        var title: String {
            switch self {
            case .googleDrive: "Google Drive"
            case .dropbox: "Dropbox"
            case .icloud: "iCloud Drive"
            }
        }
    }

    let drive: Drive
    let onAdded: () -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var provider: (any BookSourceProvider)?
    @State private var isConnecting = false
    @State private var isConnected = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    statusCard
                    capabilitiesCard
                    if let error { SourcesErrorText(message: error) }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .background(HearthBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(hearth.textSecondary)
                }
            }
        }
        .onAppear {
            if provider == nil {
                provider = makeProvider()
                checkConnection()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            SourcesProviderLogo(assetName: nil, systemName: provider?.iconName ?? "icloud", size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Overline("Cloud drive")
                Text(drive.title)
                    .font(.hearthDisplay(26))
                    .foregroundStyle(hearth.text)
            }
        }
    }

    private var statusCard: some View {
        SourcesCard {
            HStack(spacing: 10) {
                Circle()
                    .fill(isConnected ? hearth.statusOK : hearth.textTertiary)
                    .frame(width: 8, height: 8)
                Text(isConnecting ? "Connecting…" : (isConnected ? "Connected" : "Not connected"))
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                Spacer()
                if isConnecting { ProgressView().tint(hearth.ember) }
            }

            if isConnected {
                QuietButton(title: "Disconnect", systemImage: "xmark.circle") {
                    disconnect()
                }
            } else {
                EmberButton(title: "Connect to \(drive.title)", systemImage: "link", tint: nil) {
                    connect()
                }
                .disabled(isConnecting)
            }
        }
    }

    private var capabilitiesCard: some View {
        SourcesCard {
            Overline("What it can do")
            cloudCapabilityRow("Browse folders", available: provider?.capabilities.contains(.folderBrowsing) ?? false)
            cloudCapabilityRow("Stream", available: provider?.capabilities.contains(.streaming) ?? false)
            cloudCapabilityRow("Search", available: provider?.capabilities.contains(.search) ?? false)
            cloudCapabilityRow("Rich metadata", available: provider?.capabilities.contains(.metadata) ?? false)
        }
    }

    private func cloudCapabilityRow(_ title: String, available: Bool) -> some View {
        HStack {
            Text(title)
                .font(.hearthBody)
                .foregroundStyle(hearth.text)
            Spacer()
            Image(systemName: available ? "checkmark.circle.fill" : "circle.slash")
                .foregroundStyle(available ? hearth.statusOK : hearth.textTertiary)
        }
    }

    private func makeProvider() -> any BookSourceProvider {
        switch drive {
        case .googleDrive: GoogleDriveProvider()
        case .dropbox: DropboxProvider()
        case .icloud: iCloudDriveProvider()
        }
    }

    private func checkConnection() {
        guard let provider else { return }
        Task {
            switch provider.authenticationState {
            case .authenticated:
                isConnected = true
            case .tokenExpired:
                do {
                    try await provider.refreshAuthentication()
                    isConnected = true
                } catch {
                    isConnected = false
                }
            default:
                isConnected = false
            }
        }
    }

    private func connect() {
        guard let provider else { return }
        isConnecting = true
        error = nil
        Task {
            do {
                try await provider.authenticate()
                isConnected = true
                PlatformHaptics.notification(.success)
                onAdded()
            } catch {
                self.error = error.localizedDescription
                isConnected = false
            }
            isConnecting = false
        }
    }

    private func disconnect() {
        guard let provider else { return }
        Task {
            do {
                try await provider.signOut()
                isConnected = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
