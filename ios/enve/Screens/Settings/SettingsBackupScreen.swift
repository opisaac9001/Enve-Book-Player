#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct SettingsBackupScreen: View {
    var importOnly = false

    @Environment(\.hearth) private var hearth
    @Environment(\.profileSession) private var profileSession
    @Environment(ProfileSwitchCoordinator.self) private var profiles

    @State private var status: String?
    @State private var settingsExportURL: URL?
    @State private var isImportingSettings = false
    @State private var backupSheet: SettingsTransferSheet.Mode?

    private var session: ProfileSession { profileSession ?? .owner }

    private var isAuthorized: Bool {
        session.isOwner && (try? profiles.authorizeChanges(in: session)) != nil
    }

    var body: some View {
        SettingsScaffold(overline: "Settings", title: importOnly ? "Import from backup" : "Backup & transfer") {
            if let status {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(hearth.statusOK)
                    Text(status)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }

            SourcesCard {
                if !importOnly {
                    Button {
                        if isAuthorized { backupSheet = .send }
                    } label: {
                        settingsBackupLabel(
                            title: "Transfer to another device",
                            subtitle: "Show a QR code or a six-digit code",
                            systemImage: "qrcode"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-backup-send")
                    Divider().overlay(hearth.hairline)
                }
                Button {
                    if isAuthorized { backupSheet = .scan }
                } label: {
                    settingsBackupLabel(
                        title: "Scan to import",
                        subtitle: "Receive a backup from another device on the same Wi-Fi",
                        systemImage: "qrcode.viewfinder"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-backup-scan")
                Divider().overlay(hearth.hairline)
                Button {
                    if isAuthorized { backupSheet = .enterCode }
                } label: {
                    settingsBackupLabel(
                        title: "Enter a code",
                        subtitle: "Type six digits to import without a camera",
                        systemImage: "number"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-backup-enter-code")
                Divider().overlay(hearth.hairline)
                if !importOnly {
                    if let settingsExportURL {
                        ShareLink(item: settingsExportURL) {
                            settingsBackupLabel(
                                title: "Export settings only",
                                subtitle: "Save speeds, skips, sleep and display preferences to a file",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                    }
                    Divider().overlay(hearth.hairline)
                    Button {
                        if isAuthorized { backupSheet = .export }
                    } label: {
                        settingsBackupLabel(
                            title: "Create encrypted backup",
                            subtitle: "Choose settings and library sources to move to another device",
                            systemImage: "lock"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-backup-encrypted")
                    Divider().overlay(hearth.hairline)
                }
                Button {
                    isImportingSettings = isAuthorized
                } label: {
                    settingsBackupLabel(
                        title: "Import backup",
                        subtitle: "Review settings and sources before restoring them",
                        systemImage: "square.and.arrow.down"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-backup-import")
            }
        }
        .task {
            guard isAuthorized else { return }
            prepareSettingsExport()
        }
        .onChange(of: profiles.isParentAuthorized) { _, _ in
            if isAuthorized {
                prepareSettingsExport()
            } else {
                discardSettingsExport()
                backupSheet = nil
            }
        }
        .onDisappear { discardSettingsExport() }
        .sheet(item: $backupSheet) { mode in
            SettingsTransferSheet(mode: mode, session: session, onRestore: didRestoreBackup)
                .enveEnvironment(session: session)
                .hearthPresentationBackground()
        }
        .fileImporter(
            isPresented: $isImportingSettings,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    try profiles.authorizeChanges(in: session)
                    backupSheet = .restore(try SettingsBackupService.shared.readBackup(from: url))
                } catch {
                    status = error.localizedDescription
                }
            case .failure:
                break
            }
        }
    }

    private func settingsBackupLabel(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(hearth.ember)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                Text(subtitle)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func didRestoreBackup(_ result: SettingsBackupService.RestoreResult) {
        var messages: [String] = []
        if result.settingsRestored {
            messages.append("Settings restored.")
            prepareSettingsExport()
        }
        if result.restoredSources > 0 {
            messages.append(result.restoredSources == 1 ? "1 source imported." : "\(result.restoredSources) sources imported.")
        }
        if result.skippedSources > 0 {
            messages.append("\(result.skippedSources) matching sources kept.")
        }
        if result.signInsNeeded > 0 {
            messages.append("Open Sources to sign in or verify \(result.signInsNeeded) connections.")
        }
        if result.restoredIntegrations > 0 {
            messages.append("\(result.restoredIntegrations) reading integrations imported.")
        }
        if result.keptIntegrations > 0 {
            messages.append("\(result.keptIntegrations) existing reading integrations kept.")
        }
        if !result.integrationsToReconnect.isEmpty {
            messages.append("Sign in again for \(result.integrationsToReconnect.formatted(.list(type: .and))).")
        }
        status = messages.joined(separator: " ")
        if !result.sourcesToRefresh.isEmpty {
            Task { [weak session] in
                guard let session else { return }
                for id in result.sourcesToRefresh where !session.isRetired {
                    await session.catalog.refreshConnectionLibraries(providerId: id)
                }
            }
        }
    }

    private func prepareSettingsExport() {
        guard !importOnly else { return }
        discardSettingsExport()
        do {
            settingsExportURL = try SettingsBackupService.shared.exportBackup()
        } catch {
            status = "Enve couldn't prepare the settings file."
        }
    }

    private func discardSettingsExport() {
        if let settingsExportURL {
            try? FileManager.default.removeItem(at: settingsExportURL.deletingLastPathComponent())
        }
        settingsExportURL = nil
    }
}
#endif
