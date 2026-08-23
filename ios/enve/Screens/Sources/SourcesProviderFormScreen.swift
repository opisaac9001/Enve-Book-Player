import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SourcesProviderFormScreen: View {
    let capability: ConnectionCapability
    let onAdded: () -> Void

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ""
    @State private var connectionName = ""
    @State private var urlScheme: SourcesURLScheme = .https
    @State private var webdavPreset: UnifiedWebDAVPreset

    @State private var authMethod: UnifiedAuthMethod = .usernamePassword
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""

    @State private var quickConnectCode: String?
    @State private var isPollingQuickConnect = false
    @State private var connectTask: Task<Void, Never>?

    @State private var showingBrowserLogin = false
    @State private var browserHeaders: [String: String]?
    @State private var serviceClientId = ""
    @State private var serviceClientSecret = ""
    @State private var customHeaders: [SourcesCustomHeader] = []

    @State private var grimmoryRedirectURI = AppAuthRedirectURI.grimmory

    @State private var mtlsEnabled = false
    @State private var showingCertPicker = false
    @State private var mtlsCertName: String?
    @State private var mtlsCertPassword = ""
    @State private var mtlsCertValidated = false
    @State private var mtlsCertError: String?

    @State private var isConnecting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var advancedExpanded = false

    @State private var showingLibrarySelection = false
    @State private var availableLibraries: [LibraryMetadata] = []
    @State private var selectedLibraryIds: Set<String> = []
    @State private var pendingConnection: ServerConnection?

    @State private var showingWebDAVRootPicker = false
    @State private var webdavRootServer: WebDAVServerConfig?
    @State private var showingCloudFolderPicker = false
    @State private var savedConnection: ServerConnection?

    @State private var pendingAutoAuth: UnifiedAuthMethod?

    init(
        capability: ConnectionCapability,
        initialPreset: UnifiedWebDAVPreset? = nil,
        prefilledURL: String? = nil,
        autoStartAuth: UnifiedAuthMethod? = nil,
        onAdded: @escaping () -> Void
    ) {
        self.capability = capability
        self.onAdded = onAdded
        _webdavPreset = State(initialValue: initialPreset ?? .generic)
        _authMethod = State(
            initialValue: initialPreset?.preferredAuthMethod ?? (capability.providerType == .torbox ? .token : .usernamePassword)
        )
        let seededURL = prefilledURL ?? (capability.providerType == .torbox ? capability.serverURLPlaceholder : nil)
        if let prefilledURL = seededURL {
            let (scheme, host) = Self.splitScheme(prefilledURL)
            _urlScheme = State(initialValue: scheme)
            _serverURL = State(initialValue: host)
        }
        _connectionName = State(initialValue: capability.providerType == .torbox ? capability.displayName : "")
        _pendingAutoAuth = State(initialValue: autoStartAuth)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if capability.supportsWebDAVPresets { presetCard }
                    serverCard
                    if availableAuthMethods.count > 1 { authMethodPicker }
                    credentialCard
                    if let statusMessage {
                        HStack(spacing: 8) {
                            ProgressView().tint(hearth.ember)
                            Text(statusMessage)
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                    }
                    if let errorMessage { SourcesErrorText(message: errorMessage) }
                    if hasAdvancedOptions { advancedCard }
                    connectButton
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .background(HearthBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        connectTask?.cancel()
                        dismiss()
                    }
                    .foregroundStyle(hearth.textSecondary)
                }
            }
        }
        .onAppear {
            if availableAuthMethods.count == 1, let only = availableAuthMethods.first {
                authMethod = only
            }
            if capability.supportsWebDAVPresets {
                applyPreset(webdavPreset)
            }
            if let pending = pendingAutoAuth {
                pendingAutoAuth = nil
                if availableAuthMethods.contains(pending) {
                    authMethod = pending
                    if pending == .oidc || pending == .webLogin {

                        connectTask = Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            guard !Task.isCancelled else { return }
                            await connect()
                        }
                    }
                }
            }
        }
        .onDisappear { connectTask?.cancel() }
        .onChange(of: serverURL) { _, _ in
            splitSchemeIfNeeded()
            browserHeaders = nil
        }
        .onChange(of: webdavPreset) { _, newValue in
            applyPreset(newValue)
        }
        .sheet(isPresented: $showingBrowserLogin) {
            if let url = URL(string: normalizedURL), !normalizedURL.isEmpty {
                BrowserSessionLoginView(url: url) { headers in
                    browserHeaders = headers
                }
                .enveEnvironment()
            }
        }
        .sheet(isPresented: $showingLibrarySelection, onDismiss: finishAfterLibrarySelection) {
            if let conn = pendingConnection {
                LibrarySelectionView(
                    backendName: conn.name,
                    libraries: availableLibraries,
                    backendType: conn.type == .emby ? .emby : .jellyfin,
                    selectedLibraryIds: $selectedLibraryIds
                )
                .enveEnvironment()
            }
        }
        .sheet(isPresented: $showingWebDAVRootPicker, onDismiss: { onAdded() }) {
            if let server = webdavRootServer, let conn = savedConnection {
                SourcesWebDAVBrowser(server: server) { selectedPaths in
                    Task {
                        await engine.sources.updateWebDAVRoots(server: server, connectionId: conn.id, selectedPaths: selectedPaths)
                    }
                }
                .enveEnvironment()
            }
        }
        .sheet(isPresented: $showingCloudFolderPicker, onDismiss: { onAdded() }) {
            if let conn = savedConnection {
                SourcesCloudFolderBrowser(
                    connection: conn,
                    onFolderSelected: { selectedPath in
                        Task {
                            await engine.sources.updateCloudFolderRoot(connectionId: conn.id, selectedPath: selectedPath)
                        }
                    },
                    onScanAll: {
                        Task {
                            await engine.sources.updateCloudFolderRoot(connectionId: conn.id, selectedPath: nil)
                        }
                    }
                )
                .enveEnvironment()
            }
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
    }

    private var header: some View {
        HStack(spacing: 14) {
            SourcesProviderLogo(
                assetName: capability.supportsWebDAVPresets ? webdavPreset.assetIconName : capability.assetIconName,
                systemName: capability.supportsWebDAVPresets ? webdavPreset.systemIconName : capability.iconSystemName,
                size: 52
            )
            VStack(alignment: .leading, spacing: 4) {
                Overline("New source")
                Text(capability.displayName)
                    .font(.hearthDisplay(26))
                    .foregroundStyle(hearth.text)
            }
        }
    }

    private var presetCard: some View {
        SourcesCard {
            Overline("Service")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(UnifiedWebDAVPreset.allCases) { preset in
                        HearthChip(title: preset.rawValue, isSelected: webdavPreset == preset) {
                            webdavPreset = preset
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var serverCard: some View {
        SourcesCard {
            HStack(spacing: 8) {
                Menu {
                    ForEach(SourcesURLScheme.allCases, id: \.rawValue) { scheme in
                        Button(scheme.rawValue) { urlScheme = scheme }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(urlScheme.rawValue)
                            .font(.hearthUI(14, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.hearthUI(9, weight: .semibold))
                    }
                    .foregroundStyle(hearth.ember)
                }
                .disabled(presetLocksURL)
                Text("Server")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
            SourcesField(
                label: "Address",
                text: $serverURL,
                placeholder: urlPlaceholder,
                keyboard: .URL,
                disabled: presetLocksURL
            )
            SourcesField(label: "Name", text: $connectionName, placeholder: capability.displayName + " (optional)")
        }
    }

    private var authMethodPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(availableAuthMethods, id: \.rawValue) { method in
                    HearthChip(title: method.rawValue, isSelected: authMethod == method) {
                        authMethod = method
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var credentialCard: some View {
        switch authMethod {
        case .usernamePassword:
            SourcesCard {
                SourcesField(label: activeUsernameLabel, text: $username)
                SourcesField(label: activePasswordLabel, text: $password, secure: true)
                if capability.credentialsOptional {
                    Text("Leave blank if the server is open or access is handled by a browser session.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }
            }
        case .token:
            SourcesCard {
                SourcesField(label: activeTokenLabel, text: $token, secure: true)
            }
        case .quickConnect:
            SourcesCard {
                if let code = quickConnectCode {
                    VStack(alignment: .leading, spacing: 8) {
                        Overline("Enter this code on your server")
                        Text(code)
                            .font(.hearthDisplay(40))
                            .foregroundStyle(hearth.ember)
                            .frame(maxWidth: .infinity)
                        if isPollingQuickConnect {
                            HStack(spacing: 8) {
                                ProgressView().tint(hearth.ember)
                                Text("Waiting for approval…")
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textSecondary)
                            }
                        }
                    }
                } else {
                    Text("Connect will show a code to approve in your server's dashboard.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
        case .oidc:
            SourcesCard {
                Text("Connect opens your identity provider in a browser window.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                if capability.providerType == .booklore {
                    grimmoryRedirectPicker
                } else if capability.providerType == .bookOrbit {
                    bookOrbitRedirectNote
                }
            }
        case .webLogin:
            SourcesCard {
                Text("Connect signs you in through the server's own web login page.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
    }

    private var grimmoryRedirectPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Overline("Redirect URI")
            Menu {
                ForEach(AppAuthRedirectURI.grimmoryPresetOptions, id: \.self) { option in
                    Button(option) { grimmoryRedirectURI = option }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(grimmoryRedirectURI)
                        .font(.hearthCaption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.hearthUI(9, weight: .semibold))
                }
                .foregroundStyle(hearth.ember)
            }
            HStack {
                Text("Add this exact URI to your OIDC provider's allowed redirects.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                Spacer()
                Button {
                    UIPasteboard.general.string = grimmoryRedirectURI
                    PlatformHaptics.selection()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.hearthUI(13))
                        .foregroundStyle(hearth.ember)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Copy redirect URI")
            }
        }
    }

    private var bookOrbitRedirectNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Overline("Redirect URI")
            Text(
                "Use your BookOrbit server URL plus \(AppAuthRedirectURI.bookOrbitCallbackPath) in Authentik, Authelia, or your OIDC provider."
            )
            .font(.hearthCaption)
            .foregroundStyle(hearth.textTertiary)
        }
    }

    private var advancedCard: some View {
        SourcesCard {
            Button {
                withAnimation(.snappy) { advancedExpanded.toggle() }
            } label: {
                HStack {
                    Text("Advanced")
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                    if !advancedChips.isEmpty {
                        Text(advancedChips.joined(separator: " · "))
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.ember)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.hearthUI(12, weight: .semibold))
                        .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                        .foregroundStyle(hearth.textTertiary)
                }
                .contentShape(Rectangle())
            }

            if advancedExpanded {
                if capability.supportsBrowserSignIn {
                    VStack(alignment: .leading, spacing: 8) {
                        Overline("Browser session")
                        if browserHeaders != nil {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(hearth.statusOK)
                                Text("Browser session captured")
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textSecondary)
                                Spacer()
                                Button("Clear") { browserHeaders = nil }
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.ember)
                            }
                        } else {
                            QuietButton(title: "Sign in with browser", systemImage: "globe") {
                                showingBrowserLogin = true
                            }
                            .disabled(normalizedURL.isEmpty)
                            Text("For Authelia, Authentik, Cloudflare Access, and other reverse-proxy sign-ins.")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textTertiary)
                        }
                    }
                }

                if capability.supportsServiceTokens {
                    VStack(alignment: .leading, spacing: 10) {
                        Overline("Service tokens")
                        SourcesField(label: "CF-Access-Client-Id", text: $serviceClientId)
                        SourcesField(label: "CF-Access-Client-Secret", text: $serviceClientSecret, secure: true)
                    }
                }

                if capability.supportsCustomHeaders {
                    VStack(alignment: .leading, spacing: 10) {
                        Overline("Custom headers")
                        ForEach($customHeaders) { $header in
                            HStack(spacing: 8) {
                                SourcesField(label: "Header", text: $header.key)
                                SourcesField(label: "Value", text: $header.value)
                                Button {
                                    customHeaders.removeAll { $0.id == header.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(hearth.statusError)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Remove header")
                                .padding(.top, 8)
                            }
                        }
                        Button {
                            customHeaders.append(SourcesCustomHeader())
                        } label: {
                            Label("Add header", systemImage: "plus")
                                .font(.hearthCaption.weight(.medium))
                                .foregroundStyle(hearth.ember)
                        }
                    }
                }

                if capability.supportsMTLS {
                    VStack(alignment: .leading, spacing: 10) {
                        Overline("Client certificate (mTLS)")
                        SourcesToggleRow(title: "Use a client certificate", isOn: $mtlsEnabled)
                        if mtlsEnabled {
                            QuietButton(title: mtlsCertName ?? "Choose .p12 / .pfx file", systemImage: "doc.badge.plus") {
                                showingCertPicker = true
                            }
                            SourcesField(label: "Certificate password", text: $mtlsCertPassword, secure: true)
                            HStack(spacing: 8) {
                                QuietButton(title: "Validate", systemImage: nil) { validatePendingCert() }
                                if mtlsCertValidated {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(hearth.statusOK)
                                }
                            }
                            if let mtlsCertError { SourcesErrorText(message: mtlsCertError) }
                        }
                    }
                }
            }
        }
    }

    private var connectButton: some View {
        Button {
            connectTask = Task { await connect() }
        } label: {
            HStack(spacing: 8) {
                if isConnecting {
                    ProgressView()
                        .tint(hearth.onEmber)
                } else {
                    Image(systemName: "link")
                        .font(.hearthUI(15, weight: .semibold))
                }
                Text("Connect")
                    .font(.hearthUI(16, weight: .semibold))
            }
            .foregroundStyle(hearth.onEmber)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(hearth.ember, in: Capsule())
            .opacity(connectDisabled ? 0.45 : 1)
        }
        .buttonStyle(PressableStyle())
        .disabled(connectDisabled)
    }

    private var availableAuthMethods: [UnifiedAuthMethod] {
        if capability.supportsWebDAVPresets, let methods = webdavPreset.allowedAuthMethods {
            return methods
        }
        var methods: [UnifiedAuthMethod] = []
        if capability.supportsUsernamePassword { methods.append(.usernamePassword) }
        if capability.supportsToken { methods.append(.token) }
        if capability.supportsQuickConnect { methods.append(.quickConnect) }
        if capability.supportsOIDC { methods.append(.oidc) }
        if capability.supportsWebLogin { methods.append(.webLogin) }
        return methods
    }

    private var presetLocksURL: Bool {
        capability.supportsWebDAVPresets && webdavPreset.resolvedURL != nil
    }

    private var normalizedURL: String {
        if capability.supportsWebDAVPresets, let presetURL = webdavPreset.resolvedURL {
            return presetURL
        }
        var trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed = String(trimmed.dropLast())
        }
        guard !trimmed.isEmpty else { return trimmed }
        return urlScheme.rawValue + trimmed
    }

    private var urlPlaceholder: String {
        let value =
            capability.supportsWebDAVPresets
            ? (webdavPreset.resolvedURL ?? capability.serverURLPlaceholder)
            : capability.serverURLPlaceholder
        return
            value
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private var activeUsernameLabel: String {
        capability.supportsWebDAVPresets ? webdavPreset.usernameLabel : capability.credentialLabels.usernamePlaceholder
    }

    private var activePasswordLabel: String {
        capability.supportsWebDAVPresets ? webdavPreset.passwordLabel : capability.credentialLabels.passwordPlaceholder
    }

    private var activeTokenLabel: String {
        capability.supportsWebDAVPresets ? webdavPreset.tokenLabel : capability.credentialLabels.tokenPlaceholder
    }

    private var effectiveHeaders: [String: String] {
        var dict: [String: String] = [:]
        for header in customHeaders where !header.key.isEmpty {
            dict[header.key] = header.value
        }
        let merged = CloudflareAccessHeaders.mergedHeaders(
            existingHeaders: dict.isEmpty ? nil : dict,
            browserHeaders: browserHeaders,
            clientId: serviceClientId,
            clientSecret: serviceClientSecret
        )
        return merged ?? dict
    }

    private var connectDisabled: Bool {
        if isConnecting { return true }
        if normalizedURL.isEmpty { return true }
        switch authMethod {
        case .usernamePassword:
            if capability.credentialsOptional { return false }
            return username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty
        case .token:
            return token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .quickConnect, .oidc, .webLogin:
            return false
        }
    }

    private var advancedChips: [String] {
        var chips: [String] = []
        if !customHeaders.isEmpty { chips.append("\(customHeaders.count) headers") }
        if browserHeaders != nil { chips.append("browser session") }
        if !serviceClientId.isEmpty { chips.append("service token") }
        if mtlsEnabled { chips.append("mTLS") }
        return chips
    }

    private var hasAdvancedOptions: Bool {
        capability.supportsBrowserSignIn || capability.supportsCustomHeaders || capability.supportsServiceTokens || capability.supportsMTLS
    }

    private func connect() async {
        errorMessage = nil
        statusMessage = "Connecting…"
        isConnecting = true

        defer {
            isConnecting = false
            statusMessage = nil
        }

        let headers = effectiveHeaders
        let url = normalizedURL
        let usesPendingMTLS = mtlsEnabled
        if usesPendingMTLS, let host = URL(string: url)?.host {
            MTLSManager.shared.beginPendingAuthentication(forHost: host)
        }
        defer {
            if usesPendingMTLS {
                MTLSManager.shared.endPendingAuthentication()
            }
        }

        do {
            var connection: ServerConnection
            let delegate = engine.sources.makeLoginDelegate(for: capability.providerType)

            switch authMethod {
            case .usernamePassword:
                connection = try await delegate.authenticate(
                    serverURL: url,
                    username: username,
                    password: password,
                    customHeaders: headers.isEmpty ? nil : headers
                )

                if connection.password == nil, !password.isEmpty {
                    connection.password = password
                }
            case .token:
                connection = try await delegate.authenticateWithToken(
                    serverURL: url,
                    token: token,
                    customHeaders: headers.isEmpty ? nil : headers
                )
            case .quickConnect:
                statusMessage = "Generating code…"
                let result = try await delegate.startQuickConnect(
                    serverURL: url,
                    customHeaders: headers.isEmpty ? nil : headers
                )
                quickConnectCode = result.code
                isPollingQuickConnect = true
                statusMessage = "Waiting for approval…"
                defer { isPollingQuickConnect = false }
                connection = try await delegate.pollQuickConnect(
                    secret: result.secret,
                    serverURL: url,
                    customHeaders: headers.isEmpty ? nil : headers
                )
            case .oidc:
                let override: String? = (capability.providerType == .booklore) ? grimmoryRedirectURI : nil
                connection = try await delegate.authenticateWithOIDC(
                    serverURL: url,
                    redirectURIOverride: override,
                    customHeaders: headers.isEmpty ? nil : headers
                )
            case .webLogin:
                connection = try await delegate.authenticateWithWebLogin(
                    serverURL: url,
                    customHeaders: headers.isEmpty ? nil : headers
                )
            }

            if !connectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                connection.name = connectionName
            }
            if !headers.isEmpty {
                var mergedHeaders = headers
                for (key, value) in connection.customHeaders ?? [:] {
                    ServerConnection.setHeaderValue(value, for: key, in: &mergedHeaders)
                }
                connection.customHeaders = mergedHeaders
            }
            connection.mtlsEnabled = mtlsEnabled
            if mtlsEnabled {
                MTLSManager.shared.promotePendingCert(to: connection.id)
            }

            if capability.supportsLibrarySelection {
                statusMessage = "Fetching libraries…"
                let libs = try await delegate.fetchLibraries(connection: connection)
                availableLibraries = libs
                pendingConnection = connection
                showingLibrarySelection = true
            } else {
                finish(connection)
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finishAfterLibrarySelection() {
        guard let conn = pendingConnection else { return }
        pendingConnection = nil
        var final = conn
        final.selectedLibraryIds = selectedLibraryIds.isEmpty ? nil : selectedLibraryIds
        finish(final)
    }

    private func finish(_ connection: ServerConnection) {
        do {
            let completion = try engine.sources.completeAuthenticatedConnection(connection)
            PlatformHaptics.notification(.success)

            switch completion {
            case let .chooseWebDAVRoot(server, connection):
                savedConnection = connection
                webdavRootServer = server
                showingWebDAVRootPicker = true

            case let .chooseCloudFolder(connection):
                savedConnection = connection
                showingCloudFolderPicker = true

            case .completed:
                onAdded()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleCertImport(_ result: Result<URL, Error>) {
        switch result {
        case let .success(fileURL):
            guard fileURL.startAccessingSecurityScopedResource() else {
                mtlsCertError = "Unable to access the selected file."
                return
            }
            defer { fileURL.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: fileURL)
                MTLSManager.shared.storePendingCertData(data)
                mtlsCertName = fileURL.lastPathComponent
                mtlsCertValidated = false
                mtlsCertError = nil
                if !mtlsCertPassword.isEmpty { validatePendingCert() }
            } catch {
                mtlsCertError = "Could not read the selected file: \(error.localizedDescription)"
                mtlsCertValidated = false
            }
        case let .failure(error):
            mtlsCertError = error.localizedDescription
        }
    }

    private func validatePendingCert() {
        guard let data = KeychainHelper.shared.getData(MTLSManager.pendingCertKey) else {
            mtlsCertError = "Choose a .p12 / .pfx file first."
            return
        }
        do {
            let subject = try MTLSManager.shared.validatePKCS12(data, password: mtlsCertPassword)
            MTLSManager.shared.storePendingCert(data: data, password: mtlsCertPassword)
            mtlsCertName = subject
            mtlsCertValidated = true
            mtlsCertError = nil
        } catch {
            mtlsCertError = error.localizedDescription
            mtlsCertValidated = false
        }
    }

    private func applyPreset(_ preset: UnifiedWebDAVPreset) {
        if let presetURL = preset.resolvedURL {
            splitSchemeAndHost(from: presetURL)
        } else if preset == .generic,
            UnifiedWebDAVPreset.allCases.compactMap(\.suggestedName).contains(connectionName)
        {
            serverURL = ""
        }

        if let suggested = preset.suggestedName,
            connectionName.isEmpty || connectionName == "WebDAV"
                || UnifiedWebDAVPreset.allCases.compactMap(\.suggestedName).contains(connectionName)
        {
            connectionName = suggested
        } else if preset == .generic,
            UnifiedWebDAVPreset.allCases.compactMap(\.suggestedName).contains(connectionName)
        {
            connectionName = ""
        }

        authMethod = preset.preferredAuthMethod
        username = ""
        password = ""
        token = ""
    }

    private static func splitScheme(_ url: String) -> (SourcesURLScheme, String) {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var scheme: SourcesURLScheme = .https
        if value.lowercased().hasPrefix("https://") {
            scheme = .https
            value = String(value.dropFirst("https://".count))
        } else if value.lowercased().hasPrefix("http://") {
            scheme = .http
            value = String(value.dropFirst("http://".count))
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return (scheme, value)
    }

    private func splitSchemeIfNeeded() {
        let raw = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if raw.lowercased().hasPrefix("https://") || raw.lowercased().hasPrefix("http://") {
            splitSchemeAndHost(from: raw)
        }
    }

    private func splitSchemeAndHost(from rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("https://") {
            urlScheme = .https
            serverURL = String(trimmed.dropFirst("https://".count))
        } else if trimmed.lowercased().hasPrefix("http://") {
            urlScheme = .http
            serverURL = String(trimmed.dropFirst("http://".count))
        } else {
            serverURL = trimmed
        }
        while serverURL.hasSuffix("/") {
            serverURL.removeLast()
        }
    }
}
