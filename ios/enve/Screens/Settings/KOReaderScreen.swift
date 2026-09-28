import SwiftUI
import UIKit

struct KOReaderScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss

    private var service: KOReaderSyncService { .shared }

    @State private var serverURL = KOReaderSyncService.shared.config.serverURL
    @State private var username = KOReaderSyncService.shared.config.username
    @State private var password = ""
    @State private var autoSync = KOReaderSyncService.shared.config.autoSyncEnabled
    @State private var documentMatching = KOReaderSyncService.shared.config.documentMatching
    @State private var sendsMetadata = KOReaderSyncService.shared.config.sendsDocumentMetadata

    @State private var isConnecting = false
    @State private var isRegistering = false
    @State private var isSyncingNow = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    @State private var isImportingBookBridge = false
    @State private var bookBridgeMessage: String?
    @State private var bookBridgeFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
                    VStack(alignment: .leading, spacing: 6) {
                        Overline("Sync")
                        Text("KOReader")
                            .font(.hearthScreenTitle)
                            .foregroundStyle(hearth.text)
                        Text("Share reading positions with your e-reader through a KOSync server.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if service.config.isConfigured {
                    connectedCard
                    matchingCard
                    linksCard
                    bookBridgeCard
                } else {
                    connectCard
                    aboutCard
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
    }

    private var connectedCard: some View {
        SourcesCard {
            HStack(spacing: 10) {
                Circle().fill(hearth.statusOK).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.config.username)
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                    Text(service.config.serverURL)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let lastSync = service.lastSyncDate {
                Text("Last synced \(lastSync.formatted(.relative(presentation: .named)))")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }

            SourcesToggleRow(title: "Sync automatically", isOn: $autoSync)
                .onChange(of: autoSync) { _, newValue in
                    service.updateConfig(
                        serverURL: service.config.serverURL,
                        username: service.config.username,
                        plaintextPassword: nil,
                        autoSync: newValue
                    )
                }

            HStack(spacing: 10) {
                QuietButton(title: isSyncingNow ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath") {
                    guard !isSyncingNow else { return }
                    isSyncingNow = true
                    statusMessage = nil
                    Task {
                        let applied = await service.pullAllAndMerge()
                        statusMessage =
                            applied > 0
                            ? "Brought \(applied) position\(applied == 1 ? "" : "s") up to date."
                            : "Everything was already in step."
                        isSyncingNow = false
                    }
                }
                QuietButton(title: "Disconnect", systemImage: nil) {
                    service.clearConfig()
                    serverURL = ""
                    username = ""
                    password = ""
                    documentMatching = service.config.documentMatching
                    sendsMetadata = service.config.sendsDocumentMetadata
                    statusMessage = "Disconnected."
                }
            }
        }
    }

    private var matchingCard: some View {
        SourcesCard {
            Overline("Document matching")
            SettingsMenuRow(title: "Match books by", value: documentMatching.displayName) {
                ForEach(KOReaderDocumentMatching.allCases, id: \.self) { option in
                    Button(option.displayName) { apply(documentMatching: option) }
                }
            }
            Text(matchingCaption)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            SourcesToggleRow(
                title: "Send book details",
                subtitle: "Adds the file name, title, and author to each update.",
                isOn: $sendsMetadata
            )
            .onChange(of: sendsMetadata) { _, newValue in
                service.updateConfig(
                    serverURL: service.config.serverURL,
                    username: service.config.username,
                    plaintextPassword: nil,
                    autoSync: service.config.autoSyncEnabled,
                    sendsDocumentMetadata: newValue
                )
            }
        }
    }

    private var matchingCaption: String {
        switch documentMatching {
        case .binary:
            return "KOReader's default. Both devices must hold byte-identical files."
        case .filename:
            return "Matches on the file name alone, so differently converted copies still pair up."
        case .smart:
            return
                "Reads every identifier and keeps writing to whichever one your other reader used. Pick this when you do not know how the other device matches."
        }
    }

    private var linksCard: some View {
        SourcesCard {
            Overline("Linked books")
            NavigationLink {
                KOReaderLinksScreen()
            } label: {
                SettingsLinkRow(
                    title: "Manage links",
                    subtitle: "Match ebooks by KOReader document hash",
                    detail: "\(service.links.count) linked"
                )
            }
            .buttonStyle(PressableStyle())
            Text(
                "Hashes are computed automatically for on-device files; paste the hash from KOReader's Book Information page for everything else."
            )
            .font(.hearthCaption)
            .foregroundStyle(hearth.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bookBridgeCard: some View {
        SourcesCard {
            Overline("BookBridge")
            Text(
                "If your sync server is BookBridge, Enve can read the ebook and audiobook matches it already knows and link your library to Audiobookshelf counterparts."
            )
            .font(.hearthCaption)
            .foregroundStyle(hearth.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            QuietButton(
                title: isImportingBookBridge ? "Importing…" : "Import mappings",
                systemImage: "arrow.down.circle"
            ) {
                Task { await importBookBridgeMappings() }
            }
            .disabled(isImportingBookBridge || bookBridgeBaseURL() == nil)
            if let bookBridgeMessage {
                Text(bookBridgeMessage)
                    .font(.hearthCaption)
                    .foregroundStyle(bookBridgeFailed ? hearth.statusError : hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var aboutCard: some View {
        SourcesCard {
            Overline("About KOSync")
            Text(
                "KOReader identifies books by a hash of the file. Progress pushes whenever you turn a page with auto-sync on; Sync Now pulls remote progress in. You can self-host a kosync server or use a public instance like sync.koreader.rocks or CrossPoint's."
            )
            .font(.hearthCaption)
            .foregroundStyle(hearth.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectCard: some View {
        SourcesCard {
            Overline("Preset")
            HStack(spacing: 8) {
                ForEach(ServerPreset.allCases) { preset in
                    HearthChip(title: preset.title, isSelected: selectedPreset == preset) { apply(preset: preset) }
                }
            }
            Text(presetCaption)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            SourcesField(label: "Server", text: $serverURL, placeholder: "https://sync.example.com", keyboard: .URL)
            SourcesField(label: "Username", text: $username)
            SourcesField(label: "Password", text: $password, secure: true)
            SourcesToggleRow(title: "Sync automatically", isOn: $autoSync)

            HStack(spacing: 10) {
                EmberButton(title: isConnecting ? "Connecting…" : "Connect", systemImage: nil, tint: nil) {
                    connect()
                }
                .disabled(connectDisabled)
                .opacity(connectDisabled ? 0.5 : 1)

                QuietButton(title: isRegistering ? "Registering…" : "Register", systemImage: "person.crop.circle.badge.plus") {
                    registerAccount()
                }
                .disabled(connectDisabled || isRegistering)
                .opacity(connectDisabled || isRegistering ? 0.5 : 1)
            }
            Text("Register creates a new account on the server with these credentials.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private var connectDisabled: Bool {
        isConnecting || serverURL.isEmpty || username.isEmpty || password.isEmpty
    }

    private enum ServerPreset: String, CaseIterable, Identifiable {
        case crossPoint
        case koreader
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .crossPoint: return "CrossPoint"
            case .koreader: return "KOReader"
            case .custom: return "Custom"
            }
        }

        var url: String? {
            switch self {
            case .crossPoint: return KOReaderConfig.crossPointServerURL
            case .koreader: return KOReaderConfig.koreaderServerURL
            case .custom: return nil
            }
        }
    }

    private var selectedPreset: ServerPreset {
        let normalized = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ServerPreset.allCases.first { $0.url?.lowercased() == normalized } ?? .custom
    }

    private var presetCaption: String {
        switch selectedPreset {
        case .crossPoint:
            return
                "CrossPoint's free sync server speaks plain KOSync, so CrossPoint readers, KOReader, and Enve share one account. Register once, then connect with the same credentials everywhere. Picking it also matches books by file name, the way CrossPoint readers do."
        case .koreader:
            return "The public KOReader instance. Accounts are per server and are not shared with CrossPoint."
        case .custom:
            return "Point at your own kosync server, or pick a preset."
        }
    }

    private func apply(preset: ServerPreset) {
        guard let url = preset.url else { return }
        serverURL = url
        // CrossPoint firmware matches on the file name out of the box, and a content hash never
        // agrees with one, so a clean account only pairs if the first push uses the same identifier.
        if preset == .crossPoint { documentMatching = .filename }
    }

    private func apply(documentMatching option: KOReaderDocumentMatching) {
        documentMatching = option
        service.updateConfig(
            serverURL: service.config.serverURL,
            username: service.config.username,
            plaintextPassword: nil,
            autoSync: service.config.autoSyncEnabled,
            documentMatching: option
        )
    }

    private func connect() {
        isConnecting = true
        errorMessage = nil
        statusMessage = nil
        Task {
            do {
                service.updateConfig(
                    serverURL: serverURL,
                    username: username,
                    plaintextPassword: password,
                    autoSync: autoSync,
                    documentMatching: documentMatching
                )
                try await service.authorize()
                password = ""
                statusMessage = "Connected."
                PlatformHaptics.notification(.success)
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }

    private func registerAccount() {
        isRegistering = true
        errorMessage = nil
        statusMessage = nil
        Task {
            do {
                try await service.register(username: username, plaintextPassword: password, serverURL: serverURL)
                service.updateConfig(
                    serverURL: serverURL,
                    username: username,
                    plaintextPassword: password,
                    autoSync: autoSync,
                    documentMatching: documentMatching
                )
                password = ""
                statusMessage = "Account created and connected."
                PlatformHaptics.notification(.success)
            } catch {
                errorMessage = error.localizedDescription
            }
            isRegistering = false
        }
    }

    private func bookBridgeBaseURL() -> URL? {
        guard let base = service.config.baseURL else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = ""
        return components?.url
    }

    private func importBookBridgeMappings() async {
        guard let baseURL = bookBridgeBaseURL() else { return }
        isImportingBookBridge = true
        bookBridgeMessage = nil
        defer { isImportingBookBridge = false }
        do {
            let result = try await BookBridgeMappingImporter.shared.runImport(baseURL: baseURL)
            bookBridgeFailed = false
            bookBridgeMessage =
                "Linked \(result.newLinks) new, \(result.alreadyLinked) already matched. Skipped \(result.audiobookNotFound + result.ebookNotFound) without an Enve match and \(result.skippedUnlinked) unlinked rows."
            PlatformHaptics.notification(.success)
        } catch {
            bookBridgeFailed = true
            bookBridgeMessage = error.localizedDescription
        }
    }
}
