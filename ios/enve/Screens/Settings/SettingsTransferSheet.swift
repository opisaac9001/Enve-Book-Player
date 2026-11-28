#if os(iOS)
import CryptoKit
import PhotosUI
import SwiftUI

struct SettingsTransferSheet: View {
    enum Mode: Identifiable {
        case export
        case send
        case scan
        case restore(SettingsBackupService.ImportFile)

        var id: String {
            switch self {
            case .export: "export"
            case .send: "send"
            case .scan: "scan"
            case .restore: "restore"
            }
        }

        var title: String {
            switch self {
            case .export: "Encrypted backup"
            case .send: "Transfer to another device"
            case .scan: "Scan to import"
            case .restore: "Restore backup"
            }
        }
    }

    let mode: Mode
    let session: ProfileSession
    let onRestore: (SettingsBackupService.RestoreResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hearth) private var hearth
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ProfileSwitchCoordinator.self) private var profiles

    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var includeSettings = true
    @State private var includeSources = true
    @State private var includeIntegrations = true
    @State private var includeSignIns = false
    @State private var selectedSources = Set<UUID>()
    @State private var selectedIntegrations = Set<PortableSettingsBackup.Integrations.Kind>()
    @State private var preview: PortableSettingsBackup?
    @State private var exportedURL: URL?
    @State private var offer: SettingsQRTransferOffer?
    @State private var showingSignInWarning = false
    @State private var scanImage: PhotosPickerItem?
    @State private var operation: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            SettingsScaffold(
                overline: "Settings backup",
                title: mode.title,
                subtitle: nil
            ) {
                switch mode {
                case .export:
                    exportContent
                case .send:
                    sendContent
                case .scan:
                    if let preview { restoreContent(preview) } else { scanContent }
                case .restore(let file):
                    if let preview {
                        restoreContent(preview)
                    } else if case .encrypted(let backup) = file {
                        unlockContent(backup)
                    }
                }
                if let error { SourcesErrorText(message: error) }
                if operation != nil {
                    ProgressView()
                        .accessibilityLabel("Working on backup")
                }
            }
            .disabled(operation != nil)
        }
        .alert("Share your saved sign-ins?", isPresented: $showingSignInWarning) {
            Button("Transfer without sign-ins") { beginOffer(includeCredentials: false) }
            Button("Show QR code with sign-ins", role: .destructive) { beginOffer(includeCredentials: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can copy saved passwords and API keys. The other device may be able to access your accounts and libraries.\n\nOnly continue if you own and control both devices. Don’t show this code to anyone else, send a screenshot, or continue because someone asked you to share it.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, case .send = mode {
                operation?.cancel()
                offer?.close()
            }
        }
        .onChange(of: scanImage) { _, item in
            guard let item else { return }
            start {
                defer { scanImage = nil }
                guard let data = try await item.loadTransferable(type: Data.self),
                    let code = ListeningPositionQRCode.messages(inImageData: data).compactMap(SettingsTransferCode.init(text:)).first
                else { throw SettingsQRTransferError.invalidCode }
                try await receive(code)
            }
        }
        .task {
            if case .restore(.settings(let settings)) = mode {
                showPreview(PortableSettingsBackup(settings: settings, sources: []))
            }
        }
        .onDisappear {
            operation?.cancel()
            offer?.close()
            if let exportedURL {
                try? FileManager.default.removeItem(at: exportedURL.deletingLastPathComponent())
            }
        }
    }

    private var backupSelection: some View {
        SourcesCard {
            SourcesToggleRow(title: "Settings", subtitle: "Display and playback preferences", isOn: $includeSettings)
            SourcesToggleRow(title: "Library sources", subtitle: "Server addresses, accounts and library selections", isOn: $includeSources)
            SourcesToggleRow(title: "Reading integrations", subtitle: "Hardcover, Readwise and KOReader sync", isOn: $includeIntegrations)
            if includeSources || includeIntegrations {
                SourcesToggleRow(
                    title: "Include supported sign-ins",
                    subtitle: "Copies saved passwords and supported API keys. Set up browser sign-ins and client certificates again on the new device.",
                    isOn: $includeSignIns
                )
            }
        }
    }

    @ViewBuilder
    private var sendContent: some View {
        if let offer {
            SourcesCard {
                switch offer.status {
                case .waiting:
                    if let code = offer.code, let image = ListeningPositionQRCode.image(for: code.text) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 240)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("One-time transfer QR code")
                    }
                    Text("Use Scan to import in Enve on your other device. This code expires in 90 seconds.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                    QuietButton(title: "Cancel transfer", systemImage: nil) {
                        offer.close()
                        self.offer = nil
                    }
                case .sent:
                    Text("Backup sent. Review it on the other device.").font(.hearthBody)
                case .expired:
                    Text("This code has expired. Start a new transfer.").font(.hearthBody)
                    QuietButton(title: "Start again", systemImage: nil) { self.offer = nil }
                }
            }
        } else {
            backupSelection
            Text("Connect both devices to the same Wi-Fi network.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
            EmberButton(title: "Continue", systemImage: "qrcode", tint: nil) {
                if includeSignIns && (includeSources || includeIntegrations) {
                    showingSignInWarning = true
                } else {
                    beginOffer(includeCredentials: false)
                }
            }
            .disabled(!includeSettings && !includeSources && !includeIntegrations)
            .accessibilityIdentifier("settings-transfer-qr-continue")
        }
    }

    private var scanContent: some View {
        SourcesCard {
            if ListeningPositionCameraScanner.isSupported, operation == nil {
                ListeningPositionCameraScanner { message in
                    guard operation == nil, preview == nil, let code = SettingsTransferCode(text: message) else { return }
                    start { try await receive(code) }
                }
                .frame(height: 260)
                .clipShape(.rect(cornerRadius: 14))
            }
            PhotosPicker(selection: $scanImage, matching: .images) {
                Text("Choose QR image")
            }
            .foregroundStyle(hearth.ember)
            Text("Scan the one-time code displayed by Enve on your other device.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
    }

    @ViewBuilder
    private var exportContent: some View {
        if let exportedURL {
            SourcesCard {
                Text("Keep the passphrase somewhere safe. You'll need it to open this backup.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                ShareLink(item: exportedURL) {
                    Label("Share backup", systemImage: "square.and.arrow.up")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.ember)
                }
                .accessibilityIdentifier("settings-transfer-share")
            }
        } else {
            backupSelection
            SourcesCard {
                SourcesField(label: "Backup passphrase", text: $passphrase, secure: true)
                    .accessibilityIdentifier("settings-transfer-passphrase")
                SourcesField(label: "Confirm passphrase", text: $confirmation, secure: true)
                    .accessibilityIdentifier("settings-transfer-confirmation")
                Text("Use at least 12 characters. Share the backup with AirDrop or save it to Files.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
            EmberButton(title: "Create backup", systemImage: "lock", tint: nil, action: export)
                .disabled((!includeSettings && !includeSources && !includeIntegrations) || passphrase.count < 12 || passphrase != confirmation)
                .accessibilityIdentifier("settings-transfer-create")
        }
    }

    private func unlockContent(_ backup: EncryptedSettingsBackup) -> some View {
        SourcesCard {
            SourcesField(label: "Backup passphrase", text: $passphrase, secure: true)
                .accessibilityIdentifier("settings-transfer-passphrase")
            EmberButton(title: "Unlock backup", systemImage: "lock.open", tint: nil) {
                let entered = passphrase
                start {
                    let document = try await SettingsBackupService.shared.unlock(backup, passphrase: entered)
                    try authorize()
                    passphrase = ""
                    showPreview(document)
                }
            }
            .disabled(passphrase.isEmpty)
        }
    }

    @ViewBuilder
    private func restoreContent(_ backup: PortableSettingsBackup) -> some View {
        SourcesCard {
            if backup.settings != nil || backup.sharedSettings != nil {
                SourcesToggleRow(
                    title: "Restore settings", subtitle: "Applies the backup's display and playback preferences",
                    isOn: $includeSettings
                )
            }
            ForEach(backup.sources) { source in
                SourcesToggleRow(title: source.name, subtitle: source.summary, isOn: Binding(
                    get: { selectedSources.contains(source.id) },
                    set: { selected in
                        if selected { selectedSources.insert(source.id) } else { selectedSources.remove(source.id) }
                    }
                ))
            }
            if let integrations = backup.integrations {
                ForEach(integrations.available) { kind in
                    SourcesToggleRow(
                        title: kind.name,
                        subtitle: integrations.needsSignIn(kind) ? "Sign in after import" : nil,
                        isOn: Binding(
                            get: { selectedIntegrations.contains(kind) },
                            set: { selected in
                                if selected { selectedIntegrations.insert(kind) } else { selectedIntegrations.remove(kind) }
                            }
                        )
                    )
                }
            }
            if !backup.sources.isEmpty {
                Text("Existing matching sources are kept. Import backups from devices you trust.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
        EmberButton(title: "Restore selected items", systemImage: "square.and.arrow.down", tint: nil) {
            do {
                try authorize()
                let result = try SettingsBackupService.shared.restore(
                    backup, includeSettings: includeSettings, sourceIDs: selectedSources,
                    integrations: selectedIntegrations, session: session
                )
                onRestore(result)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
        .disabled(!includeSettings && selectedSources.isEmpty && selectedIntegrations.isEmpty)
        .accessibilityIdentifier("settings-transfer-restore")
    }

    private func export() {
        let copySettings = includeSettings
        let copySources = includeSources
        let copyIntegrations = includeIntegrations
        let copySignIns = includeSignIns
        let entered = passphrase
        start {
            let url = try await SettingsBackupService.shared.exportPortableBackup(
                session: session, includeSettings: copySettings, includeSources: copySources, includeIntegrations: copyIntegrations,
                includeSignIns: copySignIns, passphrase: entered
            )
            do {
                try authorize()
            } catch {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                throw error
            }
            passphrase = ""
            confirmation = ""
            exportedURL = url
        }
    }

    private func showPreview(_ backup: PortableSettingsBackup) {
        includeSettings = backup.settings != nil || backup.sharedSettings != nil
        selectedSources = Set(backup.sources.map(\.id))
        selectedIntegrations = Set(backup.integrations?.available ?? [])
        preview = backup
    }

    private func beginOffer(includeCredentials: Bool) {
        let copySettings = includeSettings
        let copySources = includeSources
        let copyIntegrations = includeIntegrations
        start {
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let passphrase = SettingsTransferCode.passphrase(for: key)
            let data = try await SettingsBackupService.shared.encryptedBackup(
                session: session, includeSettings: copySettings, includeSources: copySources,
                includeIntegrations: copyIntegrations, includeSignIns: includeCredentials, passphrase: passphrase
            )
            try authorize()
            let outgoing = try await SettingsQRTransferOffer.start(key: key, payload: data)
            do {
                try authorize()
                offer = outgoing
            } catch {
                outgoing.close()
                throw error
            }
        }
    }

    private func receive(_ code: SettingsTransferCode) async throws {
        let encrypted = try await SettingsQRTransfer.receive(code)
        let backup = try await SettingsBackupService.shared.unlock(encrypted, passphrase: code.passphrase)
        try authorize()
        showPreview(backup)
    }

    private func authorize() throws {
        try Task.checkCancellation()
        try profiles.authorizeChanges(in: session)
    }

    private func start(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        operation = Task {
            defer { operation = nil }
            do {
                try authorize()
                try await action()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
#endif
