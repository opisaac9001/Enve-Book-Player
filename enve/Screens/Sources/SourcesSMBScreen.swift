import Logging
import SwiftUI
import UIKit

struct SourcesSMBScreen: View {
    let onAdded: () -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var host = ""
    @State private var port = "445"
    @State private var shareName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var folderPath = "/"
    @State private var connectAsGuest = false

    @State private var availableShares: [String] = []
    @State private var isBrowsingShares = false
    @State private var isTestingHost = false
    @State private var hostReachable: Bool?
    @State private var isSaving = false
    @State private var error: String?
    @State private var successMessage: String?
    @State private var browsingShare: SMBBrowseTarget?

    private struct SMBBrowseTarget: Identifiable {
        let share: String
        var id: String { share }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    serverCard
                    shareCard
                    credentialsCard
                    if let error { SourcesErrorText(message: error) }
                    if let successMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(hearth.statusOK)
                            Text(successMessage)
                                .font(.hearthBody)
                                .foregroundStyle(hearth.text)
                        }
                    }
                    connectButton
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
            .sheet(item: $browsingShare) { target in
                SourcesSMBBrowser(
                    config: SMBServerConfiguration(
                        displayName: displayName.isEmpty ? "\(host)/\(target.share)" : "\(displayName)/\(target.share)",
                        hostname: host,
                        port: Int(port) ?? 445,
                        shareName: target.share,
                        username: connectAsGuest ? "" : username,
                        rootPath: "/"
                    ),
                    password: connectAsGuest ? "" : password
                ) { selectedPath in
                    shareName = target.share
                    folderPath = selectedPath.isEmpty ? "/" : selectedPath
                    availableShares = []
                }
                .enveEnvironment()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            SourcesProviderLogo(assetName: nil, systemName: "externaldrive.connected.to.line.below", size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Overline("New source")
                Text("SMB share")
                    .font(.hearthDisplay(26))
                    .foregroundStyle(hearth.text)
            }
        }
    }

    private var serverCard: some View {
        SourcesCard {
            SourcesField(label: "Name", text: $displayName, placeholder: "My NAS (optional)")
            HStack(alignment: .bottom, spacing: 10) {
                SourcesField(label: "Host", text: $host, placeholder: "192.168.1.20 or nas.local")
                Button {
                    Task { await testHost() }
                } label: {
                    Group {
                        if isTestingHost {
                            ProgressView().tint(hearth.ember)
                        } else if let hostReachable {
                            Image(systemName: hostReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(hostReachable ? hearth.statusOK : hearth.statusError)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(hearth.ember)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Test host connection")
                .disabled(host.isEmpty || isTestingHost)
            }
            SourcesField(label: "Port", text: $port, keyboard: .numberPad)
        }
    }

    private var shareCard: some View {
        SourcesCard {
            HStack(alignment: .bottom, spacing: 10) {
                SourcesField(label: "Share", text: $shareName, placeholder: "audiobooks")
                Button {
                    Task { await browseShares() }
                } label: {
                    Group {
                        if isBrowsingShares {
                            ProgressView().tint(hearth.ember)
                        } else {
                            Image(systemName: "folder.badge.questionmark")
                                .foregroundStyle(hearth.ember)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("List available shares")
                .disabled(host.isEmpty || isBrowsingShares)
            }

            if !availableShares.isEmpty {
                ForEach(availableShares, id: \.self) { share in
                    HStack(spacing: 10) {
                        Button {
                            shareName = share
                            availableShares = []
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder")
                                    .font(.hearthUI(14))
                                    .foregroundStyle(hearth.ember)
                                Text(share)
                                    .font(.hearthBody)
                                    .foregroundStyle(hearth.text)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        GlyphButton(systemImage: "chevron.right.circle", size: 36, glyphSize: 14, label: "Browse folders in \(share)") {
                            browsingShare = SMBBrowseTarget(share: share)
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                SourcesField(label: "Folder", text: $folderPath, placeholder: "/ or /Audiobooks")
                Button {
                    browsingShare = SMBBrowseTarget(share: shareName)
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .foregroundStyle(hearth.ember)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Browse for a folder")
                .disabled(host.isEmpty || shareName.isEmpty)
            }
        }
    }

    private var credentialsCard: some View {
        SourcesCard {
            SourcesToggleRow(title: "Connect as guest", isOn: $connectAsGuest)
            if !connectAsGuest {
                SourcesField(label: "Username", text: $username)
                SourcesField(label: "Password", text: $password, secure: true)
            }
        }
    }

    private var connectButton: some View {
        Button {
            connect()
        } label: {
            HStack(spacing: 8) {
                if isSaving {
                    ProgressView()
                        .tint(hearth.onEmber)
                } else {
                    Image(systemName: "link")
                        .font(.hearthUI(15, weight: .semibold))
                }
                Text(isSaving ? "Scanning the share…" : "Connect")
                    .font(.hearthUI(16, weight: .semibold))
            }
            .foregroundStyle(hearth.onEmber)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(hearth.ember, in: Capsule())
            .opacity(canConnect && !isSaving ? 1 : 0.45)
        }
        .buttonStyle(PressableStyle())
        .disabled(!canConnect || isSaving)
    }

    private var canConnect: Bool {
        !host.isEmpty && !shareName.isEmpty && Int(port) != nil && (connectAsGuest || (!username.isEmpty && !password.isEmpty))
    }

    private func testHost() async {
        guard let portNumber = Int(port), !host.isEmpty else { return }
        isTestingHost = true
        hostReachable = nil
        do {
            _ = try await SMBService().testConnection(hostname: host, port: portNumber)
            hostReachable = true
        } catch {
            hostReachable = false
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isTestingHost = false
    }

    private func browseShares() async {
        guard let portNumber = Int(port), !host.isEmpty else { return }
        isBrowsingShares = true
        error = nil
        availableShares = []
        do {
            let shares = try await SMBService().listShares(
                hostname: host,
                port: portNumber,
                username: connectAsGuest ? "" : username,
                password: connectAsGuest ? "" : password
            )
            availableShares = shares
            if shares.isEmpty {
                error = "No shares found. The server may require credentials."
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isBrowsingShares = false
    }

    private func connect() {
        guard let portNumber = Int(port) else { return }
        isSaving = true
        error = nil
        successMessage = nil

        let effectiveUsername = connectAsGuest ? "" : username
        let effectivePassword = connectAsGuest ? "" : password
        let trimmedPath = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = SMBLibrarySource(
            name: displayName.isEmpty ? host : displayName,
            hostname: host,
            port: portNumber,
            shareName: shareName,
            username: effectiveUsername,
            folderPath: trimmedPath.isEmpty ? "/" : trimmedPath
        )

        Task {
            do {
                await SMBLibraryService.shared.saveSource(source, password: effectivePassword)
                let result = try await SMBLibraryService.shared.scanLibrary(source, mode: .quick)
                AppLogger.library.info("SMB library scanned: \(result.booksFound) books found")
                successMessage = "Found \(result.booksFound) books on \(source.name)."
                NotificationCenter.default.post(name: .localLibraryUpdated, object: nil)
                PlatformHaptics.notification(.success)
                try? await Task.sleep(for: .seconds(1.2))
                onAdded()
            } catch {
                self.error = "Couldn't scan the share: \(error.localizedDescription)"
                self.isSaving = false
            }
        }
    }
}
