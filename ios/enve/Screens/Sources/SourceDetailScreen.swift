import Logging
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SourceDetailScreen: View {
    let connectionId: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var cloudflareClientId = ""
    @State private var cloudflareClientSecret = ""
    @State private var cloudflareSingleHeaderName = ""
    @State private var cloudflareBrowserHeaders: [String: String]?
    @State private var showingCloudflareLogin = false

    @State private var availableLibraries: [Library] = []
    @State private var isLoadingLibraries = false
    @State private var libraryError: String?
    @State private var draftSelectedLibraryIds: Set<String>?
    @State private var librarySelectionDirty = false
    @State private var librarySelectionStatus: String?

    @State private var plexHomeUsers: [PlexHomeUser] = []
    @State private var showingPlexUserPicker = false
    @State private var isLoadingPlexUsers = false

    @State private var webdavRootPath = "/"
    @State private var webdavIndexedPaths: [String] = ["/"]
    @State private var showingRootPicker = false

    @State private var isVerifying = false
    @State private var isReauthenticating = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showingDeleteConfirm = false
    @State private var loaded = false

    @State private var mtlsEnabled = false
    @State private var showingCertPicker = false
    @State private var mtlsCertName: String?
    @State private var mtlsCertPassword = ""
    @State private var mtlsCertError: String?

    @State private var koreaderEnabled = false
    @State private var koreaderUsername = ""
    @State private var koreaderPassword = ""
    @State private var koreaderAuthState: SourceKOReaderAuthState = .unknown
    @State private var isTestingKoreaderAuth = false

    private enum SourceKOReaderAuthState { case unknown, ok, failed }

    private var connection: ServerConnection? {
        appState.providerConnections.connections.first { $0.id == connectionId }
    }

    var body: some View {
        ScrollView {
            if let connection {
                VStack(alignment: .leading, spacing: 22) {
                    header(connection)
                    if appState.providerConnections.connectionsNeedingReauth.contains(where: { $0.id == connectionId }) {
                        reauthBanner
                    }
                    connectionCard(connection)
                    if supportsInteractiveSSO(connection) {
                        ssoCard(connection)
                    }
                    cloudflareCard
                    mtlsCard
                    if isWebDAVLike(connection) { webdavCard }
                    if connection.type == .plex { plexCard(connection) }
                    if connection.type == .booklore { koreaderCard }
                    librariesCard(connection)
                    dangerCard(connection)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, mantelInset + 16)
            }
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            guard !loaded, let connection else { return }
            loaded = true
            initializeFields(from: connection)
            restoreCachedLibraries()
            loadLibraries()
        }
        .fileImporter(
            isPresented: $showingCertPicker,
            allowedContentTypes: [
                UTType(filenameExtension: "p12") ?? .data,
                UTType(filenameExtension: "pfx") ?? .data,
            ]
        ) { result in
            handleCertImport(result)
        }
        .sheet(isPresented: $showingCloudflareLogin) {
            if let loginURL = URL(string: normalizedURL()) {
                BrowserSessionLoginView(url: loginURL) { headers in
                    cloudflareBrowserHeaders = headers
                }
                .enveEnvironment()
            }
        }
        .sheet(isPresented: $showingRootPicker) {
            if let server = webdavBrowseServer() {
                SourcesWebDAVBrowser(server: server) { selectedPaths in
                    let normalized = normalizedWebDAVPaths(selectedPaths)
                    webdavIndexedPaths = normalized.isEmpty ? ["/"] : normalized
                    webdavRootPath = webdavIndexedPaths.first ?? "/"
                    persistWebDAVServerChanges()
                    mutateConnection { $0.rootPath = webdavRootPath }
                    Task { await LibraryCatalogCoordinator.shared.refreshConnectionLibraries(providerId: connectionId) }
                }
                .enveEnvironment()
            }
        }
        .sheet(isPresented: $showingPlexUserPicker) {
            if let connection {
                SourcesPlexUserPicker(
                    users: plexHomeUsers,
                    ownerToken: connection.plexOwnerToken ?? PlexAuthStore.shared.loadToken() ?? connection.token ?? "",
                    onSelect: { user, effectiveToken in
                        showingPlexUserPicker = false
                        applyPlexUserSwitch(user: user, effectiveToken: effectiveToken)
                    },
                    onSkip: { showingPlexUserPicker = false }
                )
                .enveEnvironment()
            }
        }
        .confirmationDialog("Remove this source?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Archive source") { archive() }
            Button("Remove completely", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Archiving keeps your sign-in for later. Removing deletes everything.")
        }
    }

    private func header(_ connection: ServerConnection) -> some View {
        HStack(spacing: 14) {
            GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
            SourcesProviderLogo(assetName: connection.iconAssetName, systemName: connection.iconSystemName, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Overline(connection.isArchived ? "Archived source" : "Source")
                Text(connection.name)
                    .font(.hearthDisplay(26))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                Text(URL(string: connection.url)?.host ?? connection.url)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
    }

    private var reauthBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(hearth.statusWarn)
            Text("This source needs you to sign in again.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
    }

    private func connectionCard(_ connection: ServerConnection) -> some View {
        SourcesCard {
            SourcesField(label: "Name", text: $name)
            SourcesField(label: "Address", text: $url, keyboard: .URL)
            if !isTorBoxConnection(connection) {
                SourcesField(label: "Username", text: $username)
            }
            if !isKomgaSSO(connection) {
                SourcesField(label: secretLabel(for: connection), text: $secret, secure: true)
            }

            if let statusMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(hearth.statusOK)
                    Text(statusMessage)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            if let errorMessage { SourcesErrorText(message: errorMessage) }

            HStack(spacing: 10) {
                QuietButton(title: isVerifying ? "Checking…" : "Verify", systemImage: nil) { verify() }
                    .disabled(isVerifying)
                EmberButton(title: "Save", systemImage: nil, tint: nil) {
                    saveChanges()
                    PlatformHaptics.notification(.success)
                }
            }
        }
    }

    private func ssoCard(_ connection: ServerConnection) -> some View {
        SourcesCard {
            Overline("Single sign-on")
            Text("Signed in through your identity provider.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
            QuietButton(
                title: isReauthenticating ? "Waiting for the browser…" : "Sign in again",
                systemImage: "person.crop.circle.badge.checkmark"
            ) {
                reauthenticateSSO(connection)
            }
            .disabled(isReauthenticating)
        }
    }

    private var cloudflareCard: some View {
        SourcesCard {
            Overline("Browser session")
            if cloudflareBrowserHeaders != nil {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(hearth.statusOK)
                    Text("Browser session captured. Save to apply.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                    Spacer()
                    Button("Clear") { cloudflareBrowserHeaders = nil }
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.ember)
                }
            } else {
                QuietButton(title: "Sign in with browser", systemImage: "globe") {
                    showingCloudflareLogin = true
                }
            }
            Overline("Cloudflare service token")
            SourcesField(label: "Client ID", text: $cloudflareClientId)
            SourcesField(label: "Client secret", text: $cloudflareClientSecret, secure: true)
            SourcesField(label: "Single header name", text: $cloudflareSingleHeaderName, placeholder: "Optional")
        }
    }

    private var mtlsCard: some View {
        SourcesCard {
            Overline("Client certificate")
            SourcesToggleRow(
                title: "Use mTLS",
                subtitle: "Present a client certificate when this server asks for one",
                isOn: Binding(
                    get: { mtlsEnabled },
                    set: { value in
                        mtlsEnabled = value
                        mutateConnection { $0.mtlsEnabled = value }
                    }
                )
            )
            if mtlsEnabled {
                if let mtlsCertName {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(hearth.statusOK)
                        Text(mtlsCertName)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                } else {
                    SourcesField(label: "Certificate password", text: $mtlsCertPassword, secure: true)
                }
                QuietButton(
                    title: mtlsCertName == nil ? "Import .p12 / .pfx certificate" : "Import a different certificate",
                    systemImage: "key"
                ) {
                    if mtlsCertName != nil {
                        mtlsCertName = nil
                        mtlsCertPassword = ""
                    }
                    showingCertPicker = true
                }
                if let mtlsCertError { SourcesErrorText(message: mtlsCertError) }
            }
        }
    }

    private var koreaderCard: some View {
        SourcesCard {
            Overline("KOReader sync")
            SourcesToggleRow(
                title: "Sync with KOReader",
                subtitle: "Through this server's built-in KOReader endpoint. No separate sync server.",
                isOn: Binding(
                    get: { koreaderEnabled },
                    set: { value in
                        koreaderEnabled = value
                        saveKoreaderCredentials()
                    }
                )
            )
            if koreaderEnabled {
                SourcesField(label: "KOReader username", text: $koreaderUsername)
                    .onChange(of: koreaderUsername) { _, _ in koreaderAuthState = .unknown }
                SourcesField(label: "KOReader password", text: $koreaderPassword, secure: true)
                    .onChange(of: koreaderPassword) { _, _ in koreaderAuthState = .unknown }
                HStack(spacing: 8) {
                    QuietButton(
                        title: isTestingKoreaderAuth ? "Verifying…" : "Verify credentials",
                        systemImage: koreaderAuthGlyph
                    ) {
                        testKoreaderAuth()
                    }
                    .disabled(isTestingKoreaderAuth || koreaderUsername.isEmpty || koreaderPassword.isEmpty)
                    if koreaderAuthState == .ok {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(hearth.statusOK)
                    } else if koreaderAuthState == .failed {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(hearth.statusError)
                    }
                }
            }
        }
    }

    private var koreaderAuthGlyph: String {
        switch koreaderAuthState {
        case .unknown: "person.badge.key"
        case .ok: "checkmark.circle"
        case .failed: "xmark.circle"
        }
    }

    private var webdavCard: some View {
        SourcesCard {
            HStack {
                Overline(webdavIndexedPaths.count > 1 ? "Root folders" : "Root folder")
                Spacer()
                QuietButton(title: "Browse", systemImage: "folder") {
                    showingRootPicker = true
                }
                .disabled(webdavBrowseServer() == nil)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(webdavIndexedPaths.isEmpty ? [webdavRootPath] : webdavIndexedPaths, id: \.self) { path in
                    Text(path)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func plexCard(_ connection: ServerConnection) -> some View {
        SourcesCard {
            Overline("Plex account")
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.hearthUI(28))
                    .foregroundStyle(hearth.ember)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.plexHomeUserName ?? "Owner account")
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                    Text(
                        connection.plexHomeUserName == nil
                            ? "Signed in as the server owner"
                            : (connection.plexHomeUserIsManaged == true ? "Managed user" : "Home user")
                    )
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
            }
            QuietButton(title: isLoadingPlexUsers ? "Looking…" : "Switch user", systemImage: "person.2") {
                fetchPlexUsers(connection)
            }
            .disabled(isLoadingPlexUsers)
        }
    }

    private func librariesCard(_ connection: ServerConnection) -> some View {
        SourcesCard {
            HStack {
                Overline("Libraries")
                Spacer()
                if !availableLibraries.isEmpty {
                    Button(isAllSelected() ? "Choose some" : "All") {
                        toggleAllLibraries()
                    }
                    .font(.hearthCaption.weight(.medium))
                    .foregroundStyle(hearth.ember)
                    .frame(minWidth: 72, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
                }
            }

            if isLoadingLibraries {
                HStack(spacing: 8) {
                    ProgressView().tint(hearth.ember)
                    Text("Asking the server…")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            } else if let libraryError {
                SourcesErrorText(message: libraryError)
                QuietButton(title: "Try again", systemImage: nil) { loadLibraries() }
            } else if availableLibraries.isEmpty {
                Text("No libraries to choose from.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            } else {
                ForEach(availableLibraries, id: \.id) { library in
                    Button {
                        toggleLibrary(library.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: iconForLibraryType(library.type))
                                .font(.hearthUI(14))
                                .foregroundStyle(hearth.ember)
                                .frame(width: 22)
                            Text(library.name)
                                .font(.hearthBody)
                                .foregroundStyle(hearth.text)
                            Spacer()
                            Image(systemName: isLibrarySelected(library.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isLibrarySelected(library.id) ? hearth.ember : hearth.textTertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
                if librarySelectionDirty {
                    HStack(spacing: 10) {
                        QuietButton(title: "Reset", systemImage: nil) {
                            resetLibraryDraft(from: connection)
                        }
                        EmberButton(title: "Apply", systemImage: nil, tint: nil) {
                            applyLibrarySelection()
                        }
                    }
                }
                if let librarySelectionStatus {
                    Text(librarySelectionStatus)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Text("Everything is included unless you choose otherwise.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
        }
    }

    private func dangerCard(_ connection: ServerConnection) -> some View {
        SourcesCard {
            if connection.isArchived {
                Button {
                    let requiresReauthentication = AuthenticationFailureStore.shared.isBlocked(
                        connectionId: connectionId
                    )
                    mutateConnection { $0.isArchived = false }
                    if !requiresReauthentication {
                        Task { await SourcesFinalizer.importAndSync(providerId: connectionId) }
                    }
                    dismiss()
                } label: {
                    Label("Restore this source", systemImage: "arrow.uturn.backward")
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.ember)
                }
            } else {
                Button {
                    showingDeleteConfirm = true
                } label: {
                    Label("Remove this source", systemImage: "trash")
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.statusError)
                }
            }
        }
    }

    private func initializeFields(from connection: ServerConnection) {
        name = connection.name
        url = connection.url
        username = isTorBoxConnection(connection) ? "" : (connection.username ?? "")
        webdavRootPath = connection.rootPath ?? "/"
        if isWebDAVLike(connection) {
            let existing = RemoteImportService.shared.webDAVServers.first { $0.id == connection.id.uuidString }
            webdavIndexedPaths = normalizedWebDAVPaths(
                existing?.indexedPaths.isEmpty == false ? existing?.indexedPaths ?? [] : [webdavRootPath]
            )
        }

        if isWebDAVLike(connection) {
            secret = connection.password ?? connection.token ?? ""
        } else if connection.type == .audiobookshelf && connection.username != nil {
            secret = connection.password ?? connection.token ?? ""
        } else {
            secret = connection.token ?? ""
        }

        if let config = CloudflareAccessHeaders.detectedServiceTokenConfiguration(from: connection.customHeaders) {
            cloudflareClientId = config.clientId
            cloudflareClientSecret = config.clientSecret
            cloudflareSingleHeaderName = config.singleHeaderName ?? ""
        }
        let detectedBrowserHeaders = CloudflareAccessHeaders.detectedBrowserHeaders(from: connection.customHeaders)
        cloudflareBrowserHeaders =
            isKomgaSSO(connection)
            ? removingCookie(named: "KOMGA-SESSION", from: detectedBrowserHeaders)
            : detectedBrowserHeaders

        mtlsEnabled = connection.mtlsEnabled
        if connection.mtlsEnabled,
            let certData = KeychainHelper.shared.getData(MTLSManager.certKey(for: connection.id))
        {
            let storedPassword = KeychainHelper.shared.get(MTLSManager.certPassKey(for: connection.id)) ?? ""
            if storedPassword == "__keychain_identity__" {
                mtlsCertName = "Keychain identity"
            } else if let name = try? MTLSManager.shared.validatePKCS12(certData, password: storedPassword) {
                mtlsCertName = name
            } else {
                mtlsCertName = "Certificate installed"
            }
        }

        if connection.type == .booklore,
            let creds = BookloreKoreaderSink.shared.credentials(for: connection.id)
        {
            koreaderUsername = creds.username
            koreaderEnabled = creds.enabled

        }
        resetLibraryDraft(from: connection)
    }

    private func handleCertImport(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else {
                mtlsCertError = "Couldn't open the selected file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: url)
                let certName = try MTLSManager.shared.validatePKCS12(data, password: mtlsCertPassword)
                KeychainHelper.shared.set(data, key: MTLSManager.certKey(for: connectionId))
                if !mtlsCertPassword.isEmpty {
                    KeychainHelper.shared.set(mtlsCertPassword, key: MTLSManager.certPassKey(for: connectionId))
                }
                mtlsCertName = certName
                mtlsCertError = nil
                mutateConnection { $0.mtlsEnabled = true }
                PlatformHaptics.notification(.success)
            } catch {
                mtlsCertError = error.localizedDescription
            }
        case .failure(let error):
            mtlsCertError = error.localizedDescription
        }
    }

    private func saveKoreaderCredentials() {
        let passwordMD5 =
            koreaderPassword.isEmpty
            ? (BookloreKoreaderSink.shared.credentials(for: connectionId)?.passwordMD5 ?? "")
            : BookloreKoreaderSink.md5Hex(koreaderPassword)
        let creds = BookloreKoreaderCredentials(
            username: koreaderUsername,
            passwordMD5: passwordMD5,
            enabled: koreaderEnabled
        )
        BookloreKoreaderSink.shared.setCredentials(creds, for: connectionId)
    }

    private func testKoreaderAuth() {
        guard let baseURL = URL(string: normalizedURL()) else { return }
        isTestingKoreaderAuth = true
        let creds = BookloreKoreaderCredentials(
            username: koreaderUsername,
            passwordMD5: BookloreKoreaderSink.md5Hex(koreaderPassword),
            enabled: koreaderEnabled
        )
        BookloreKoreaderSink.shared.setCredentials(creds, for: connectionId)
        Task {
            let ok = (try? await BookloreKoreaderSink.shared.testAuth(providerId: connectionId, baseURL: baseURL)) ?? false
            isTestingKoreaderAuth = false
            koreaderAuthState = ok ? .ok : .failed
            if ok {
                saveKoreaderCredentials()
                PlatformHaptics.notification(.success)
            }
        }
    }

    private func secretLabel(for connection: ServerConnection) -> String {
        switch connection.type {
        case .webdav where !isTorBoxConnection(connection): return "Password"
        case .webdav, .torbox: return "API Token"
        case .audiobookshelf: return connection.username == nil ? "Token" : "Password"
        default: return connection.authMode == .usernamePassword ? "Password" : "Token"
        }
    }

    private func applyEdits(to conn: inout ServerConnection) {
        let komgaSessionCookie =
            isKomgaSSO(conn)
            ? cookiePair(named: "KOMGA-SESSION", in: conn.customHeaders)
            : nil

        conn.name = name
        conn.url = url.hasPrefix("http") ? url : "https://" + url
        if isTorBoxConnection(conn) {
            conn.username = nil
        } else {
            conn.username = username.isEmpty ? nil : username
        }

        if isTorBoxConnection(conn) {
            conn.password = nil
            conn.token = secret.isEmpty ? nil : secret
        } else if conn.type == .webdav {
            conn.password = secret.isEmpty ? nil : secret
            conn.token = nil
        } else if conn.authMode == .token || conn.authMode == .sso {
            conn.token = secret.isEmpty ? nil : secret
            conn.password = nil
        } else if conn.type == .audiobookshelf && !username.isEmpty && !secret.isEmpty {
            conn.password = secret
            if conn.token?.contains(".") != true { conn.token = nil }
        } else {
            conn.token = secret.isEmpty ? nil : secret
        }

        var existingHeaders = conn.customHeaders
        existingHeaders = existingHeaders?.filter {
            $0.key.caseInsensitiveCompare(CloudflareAccessHeaders.cookieHeader) != .orderedSame
        }
        var mergedHeaders = CloudflareAccessHeaders.mergedHeaders(
            existingHeaders: existingHeaders,
            browserHeaders: cloudflareBrowserHeaders,
            clientId: cloudflareClientId,
            clientSecret: cloudflareClientSecret,
            singleHeaderName: cloudflareSingleHeaderName
        )
        if let komgaSessionCookie {
            mergedHeaders = addingCookiePair(
                komgaSessionCookie,
                named: "KOMGA-SESSION",
                to: mergedHeaders
            )
        }
        conn.customHeaders = mergedHeaders
    }

    private func saveChanges() {
        let previousURL = connection?.url
        let previousUsername = connection?.username
        mutateConnection { applyEdits(to: &$0) }

        if let conn = connection, conn.type == .booklore,
            conn.url != previousURL || conn.username != previousUsername
        {
            UserDefaults.standard.removeObject(forKey: "BookloreTier-\(connectionId.uuidString)")
        }
        if let connection, isWebDAVLike(connection) {
            persistWebDAVServerChanges()
        }
        statusMessage = "Saved."
    }

    private func verify() {
        guard let connection else { return }
        isVerifying = true
        errorMessage = nil
        statusMessage = nil
        Task {
            do {
                var candidate = connection
                applyEdits(to: &candidate)
                let credentialsMatchSaved =
                    candidate.url == connection.url
                    && candidate.username == connection.username
                    && candidate.password == connection.password
                    && candidate.token == connection.token
                    && candidate.customHeaders == connection.customHeaders
                let (isValid, validatedConnection) = try await appState.validateConnection(candidate)
                if isValid {
                    if credentialsMatchSaved {
                        appState.providerConnections.updateToken(validatedConnection)
                        mutateConnection {
                            $0.isConnected = true
                            $0.lastVerified = Date()
                        }
                        AuthenticationFailureStore.shared.clear(connectionId: connection.id)
                        appState.providerConnections.clearReauthentication(connectionId: connection.id)
                    }
                    statusMessage = "Connection looks good."
                    PlatformHaptics.notification(.success)
                } else {
                    errorMessage = "The server didn't accept these credentials."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isVerifying = false
        }
    }

    private func reauthenticateSSO(_ connection: ServerConnection) {
        isReauthenticating = true
        errorMessage = nil
        Task {
            do {
                let fresh: ServerConnection
                let refreshKeyPrefix: String
                if connection.type == .audiobookshelf {
                    fresh = try await AudiobookshelfLoginDelegate().authenticateWithOIDC(
                        serverURL: connection.url,
                        redirectURIOverride: nil,
                        customHeaders: connection.customHeaders
                    )
                    refreshKeyPrefix = "abs_refresh_"
                } else if connection.type == .bookOrbit {
                    fresh = try await BookOrbitLoginDelegate(appState: appState).authenticateWithOIDC(
                        serverURL: connection.url,
                        redirectURIOverride: nil,
                        customHeaders: connection.customHeaders
                    )
                    refreshKeyPrefix = "bookorbit_refresh_"
                } else if connection.type == .komga {
                    fresh = try await KomgaLoginDelegate(appState: appState).authenticateWithOIDC(
                        serverURL: connection.url,
                        preferredProviderId: connection.komgaOAuthProviderId,
                        customHeaders: connection.customHeaders
                    )
                    refreshKeyPrefix = ""
                } else {
                    fresh = try await GrimmoryLoginDelegate(appState: appState).authenticateWithOIDC(
                        serverURL: connection.url,
                        redirectURIOverride: connection.grimmoryOIDCRedirectURI,
                        customHeaders: connection.customHeaders
                    )
                    refreshKeyPrefix = "booklore_refresh_"
                }

                if !refreshKeyPrefix.isEmpty,
                    let refresh = KeychainHelper.shared.get(refreshKeyPrefix + fresh.id.uuidString)
                {
                    KeychainHelper.shared.set(refresh, key: refreshKeyPrefix + connection.id.uuidString)
                    KeychainHelper.shared.delete(refreshKeyPrefix + fresh.id.uuidString)
                }

                mutateConnection {
                    $0.token = fresh.token
                    $0.userId = fresh.userId ?? $0.userId
                    $0.username = fresh.username ?? $0.username
                    $0.customHeaders = fresh.customHeaders
                    $0.authMode = fresh.authMode
                    $0.komgaOAuthProviderId = fresh.komgaOAuthProviderId ?? $0.komgaOAuthProviderId
                    $0.isConnected = true
                    $0.lastVerified = Date()
                }
                AuthenticationFailureStore.shared.clear(connectionId: connection.id)
                appState.providerConnections.clearReauthentication(connectionId: connection.id)
                secret = fresh.token ?? ""
                let detectedBrowserHeaders = CloudflareAccessHeaders.detectedBrowserHeaders(from: fresh.customHeaders)
                cloudflareBrowserHeaders =
                    isKomgaSSO(fresh)
                    ? removingCookie(named: "KOMGA-SESSION", from: detectedBrowserHeaders)
                    : detectedBrowserHeaders
                statusMessage = "Signed in again."
                PlatformHaptics.notification(.success)
            } catch {
                errorMessage = error.localizedDescription
            }
            isReauthenticating = false
        }
    }

    private func supportsInteractiveSSO(_ connection: ServerConnection) -> Bool {
        guard connection.authMode == .sso else { return false }
        return connection.type == .audiobookshelf
            || connection.type == .booklore
            || connection.type == .bookOrbit
            || connection.type == .komga
    }

    private func isKomgaSSO(_ connection: ServerConnection) -> Bool {
        connection.type == .komga && connection.authMode == .sso
    }

    private func cookiePair(named name: String, in headers: [String: String]?) -> String? {
        guard let cookieHeader = ServerConnection.headerValue(in: headers, for: "Cookie") else {
            return nil
        }
        return
            cookieHeader
            .split(separator: ";")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { pair in
                pair.split(separator: "=", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(name) == .orderedSame
            }
    }

    private func removingCookie(
        named name: String,
        from headers: [String: String]?
    ) -> [String: String]? {
        guard var headers,
            let cookieHeader = ServerConnection.headerValue(in: headers, for: "Cookie")
        else {
            return headers
        }

        let remaining =
            cookieHeader
            .split(separator: ";")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { pair in
                pair.split(separator: "=", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(name) != .orderedSame
            }
            .joined(separator: "; ")

        let cookieKeys = headers.keys.filter {
            $0.caseInsensitiveCompare("Cookie") == .orderedSame
        }
        for key in cookieKeys {
            headers.removeValue(forKey: key)
        }
        if !remaining.isEmpty {
            headers["Cookie"] = remaining
        }
        return headers.isEmpty ? nil : headers
    }

    private func addingCookiePair(
        _ pair: String,
        named name: String,
        to headers: [String: String]?
    ) -> [String: String] {
        var result = removingCookie(named: name, from: headers) ?? [:]
        let existing = ServerConnection.headerValue(in: result, for: "Cookie")
        let cookieHeader = [existing, pair]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        ServerConnection.setHeaderValue(cookieHeader, for: "Cookie", in: &result)
        return result
    }

    private func isAllSelected() -> Bool {
        guard let selected = draftSelectedLibraryIds else { return true }
        return selected.count == availableLibraries.count
    }

    private func isLibrarySelected(_ id: String) -> Bool {
        guard let selected = draftSelectedLibraryIds else { return true }
        return selected.contains(id)
    }

    private func toggleLibrary(_ id: String) {
        let allLibraryIds = Set(availableLibraries.map(\.id))
        var updated = draftSelectedLibraryIds ?? allLibraryIds
        if updated.contains(id) {
            updated.remove(id)
        } else {
            updated.insert(id)
        }
        draftSelectedLibraryIds = updated.count == allLibraryIds.count ? nil : updated
        librarySelectionDirty = true
        librarySelectionStatus = "Library choices ready to apply."
    }

    private func toggleAllLibraries() {
        if let selected = draftSelectedLibraryIds, selected.count != availableLibraries.count {
            draftSelectedLibraryIds = nil
        } else {
            draftSelectedLibraryIds = []
        }
        librarySelectionDirty = true
        librarySelectionStatus = "Library choices ready to apply."
    }

    private func applyLibrarySelection() {
        mutateConnection {
            $0.selectedLibraryIds = draftSelectedLibraryIds
        }
        librarySelectionDirty = false
        librarySelectionStatus = "Library choices saved."
        PlatformHaptics.notification(.success)
    }

    private func resetLibraryDraft(from connection: ServerConnection) {
        draftSelectedLibraryIds = connection.selectedLibraryIds
        librarySelectionDirty = false
        librarySelectionStatus = nil
    }

    private func restoreCachedLibraries() {
        let cached = LibraryCatalogCoordinator.shared.libraries
            .filter { $0.providerId == connectionId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !cached.isEmpty { availableLibraries = cached }
    }

    private func loadLibraries() {
        guard let connection, !connection.isArchived else { return }
        isLoadingLibraries = availableLibraries.isEmpty
        libraryError = nil
        Task {
            do {
                guard let provider = ProviderFactory.create(for: connection) else {
                    libraryError = "This source doesn't list libraries."
                    isLoadingLibraries = false
                    return
                }
                availableLibraries = try await provider.fetchLibraries()
            } catch {
                if availableLibraries.isEmpty {
                    libraryError = error.localizedDescription
                }
            }
            isLoadingLibraries = false
        }
    }

    private func iconForLibraryType(_ type: String) -> String {
        switch type.lowercased() {
        case "book": return "book"
        case "podcast": return "mic"
        default: return "folder"
        }
    }

    private func fetchPlexUsers(_ connection: ServerConnection) {
        isLoadingPlexUsers = true
        errorMessage = nil
        Task {
            do {
                let ownerToken = connection.plexOwnerToken ?? PlexAuthStore.shared.loadToken() ?? ""
                plexHomeUsers = try await PlexService().getPlexHomeUsers(token: ownerToken)
                isLoadingPlexUsers = false
                showingPlexUserPicker = true
            } catch {
                isLoadingPlexUsers = false
                errorMessage = "Couldn't load accounts: \(error.localizedDescription)"
            }
        }
    }

    private func applyPlexUserSwitch(user: PlexHomeUser, effectiveToken: String) {
        guard let connection else { return }
        Task {
            let ownerToken = connection.plexOwnerToken ?? PlexAuthStore.shared.loadToken() ?? connection.token ?? ""
            let resolvedServerToken: String? =
                user.isAdmin
                ? nil
                : await PlexService().resolveServerAccessToken(
                    userToken: effectiveToken,
                    serverUrl: connection.url,
                    ownerToken: ownerToken,
                    switchedUserId: user.id
                )

            mutateConnection { conn in
                if user.isAdmin {
                    conn.plexHomeUserId = nil
                    conn.plexHomeUserName = nil
                    conn.plexHomeUserThumb = nil
                    conn.plexHomeUserToken = nil
                    conn.plexHomeUserIsManaged = nil
                } else {
                    conn.plexHomeUserId = user.id
                    conn.plexHomeUserName = user.displayName
                    conn.plexHomeUserThumb = user.thumb
                    conn.plexHomeUserToken = resolvedServerToken
                    conn.plexHomeUserIsManaged = user.isManaged
                    if conn.plexOwnerToken == nil { conn.plexOwnerToken = ownerToken }
                }
            }
            availableLibraries = []
            await LibraryCatalogCoordinator.shared.refreshConnectionLibraries(providerId: connectionId)
            loadLibraries()
        }
    }

    private func webdavBrowseServer() -> WebDAVServerConfig? {
        guard let connection else { return nil }
        let baseURL: URL
        if isTorBoxConnection(connection) {
            baseURL = URL(string: "https://webdav.torbox.app")!
        } else {
            guard let resolved = URL(string: normalizedURL()) else { return nil }
            baseURL = resolved
        }
        let existing = RemoteImportService.shared.webDAVServers.first { $0.id == connectionId.uuidString }
        return WebDAVServerConfig(
            id: existing?.id ?? connectionId.uuidString,
            name: name.isEmpty ? (isTorBoxConnection(connection) ? "TorBox" : "WebDAV Server") : name,
            baseURL: baseURL,
            username: isTorBoxConnection(connection) ? "torbox" : (username.isEmpty ? nil : username),
            password: secret.isEmpty ? nil : secret,
            rootPath: webdavRootPath,
            indexedPaths: webdavIndexedPaths
        )
    }

    private func persistWebDAVServerChanges() {
        guard let connection, isWebDAVLike(connection), var server = webdavBrowseServer() else { return }
        server.rootPath = webdavRootPath
        server.indexedPaths = webdavIndexedPaths
        RemoteImportService.shared.saveWebDAVServer(server)
    }

    private func isTorBoxConnection(_ connection: ServerConnection) -> Bool {
        if connection.type == .torbox { return true }
        guard let host = URL(string: connection.url)?.host?.lowercased() else { return false }
        return host.contains("torbox")
    }

    private func isWebDAVLike(_ connection: ServerConnection) -> Bool {
        connection.type == .webdav || connection.type == .torbox || isTorBoxConnection(connection)
    }

    private func normalizedWebDAVPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            var normalized = trimmed.isEmpty ? "/" : trimmed
            if !normalized.hasPrefix("/") { normalized = "/" + normalized }
            if normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }

    private func archive() {
        mutateConnection { $0.isArchived = true }
        dismiss()
    }

    private func delete() {
        guard let connection else { return }
        if connection.type == .plex {
            PlexAuthStore.shared.saveServerUrl("")
        }
        if connection.mtlsEnabled {
            MTLSManager.shared.deleteCert(for: connection.id)
        }
        if let index = appState.providerConnections.connections.firstIndex(where: { $0.id == connectionId }) {
            appState.providerConnections.connections.remove(at: index)
        }
        AuthenticationFailureStore.shared.clear(connectionId: connectionId)
        appState.providerConnections.clearReauthentication(connectionId: connectionId)
        dismiss()
    }

    private func mutateConnection(_ mutate: (inout ServerConnection) -> Void) {
        guard let index = appState.providerConnections.connections.firstIndex(where: { $0.id == connectionId }) else { return }
        var updated = appState.providerConnections.connections[index]
        mutate(&updated)
        appState.providerConnections.connections[index] = updated
    }

    private func normalizedURL() -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return trimmed.hasPrefix("http") ? trimmed : "https://" + trimmed
    }
}
