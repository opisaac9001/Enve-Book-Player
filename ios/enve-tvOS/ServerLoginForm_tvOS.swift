import SwiftUI

struct ServerLoginForm_tvOS: View {
    let backend: AddServerView_tvOS.Backend
    private let original: ServerConnection?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hearth) private var hearth
    @Environment(AppState.self) private var appState

    private var capability: TVServerCapability { TVServerCapability.forBackend(backend) }

    @State private var authMethod: TVAuthMethod
    @State private var displayName: String
    @State private var serverURL: String
    @State private var username: String
    @State private var password: String = ""
    @State private var apiToken: String = ""
    @State private var webDAVPreset: TVWebDAVPreset
    @State private var customHeaderKey: String = ""
    @State private var customHeaderValue: String = ""

    @State private var isVerifying = false
    @State private var errorMessage: String?

    private let fieldWidth: CGFloat = 1100

    init(backend: AddServerView_tvOS.Backend, editing original: ServerConnection? = nil) {
        self.backend = backend
        self.original = original
        let capability = TVServerCapability.forBackend(backend)
        if let original {
            let originalURL = Self.normalizedServerURL(original.url)
            _authMethod = State(initialValue: Self.authMethod(for: original))
            _displayName = State(initialValue: original.name)
            _serverURL = State(initialValue: original.url)
            _username = State(initialValue: original.username ?? "")
            _webDAVPreset = State(
                initialValue: capability.webDAVPresets.first { $0.resolvedURL.map(Self.normalizedServerURL) == originalURL } ?? .generic
            )
        } else {
            let preset = capability.webDAVPresets.first ?? .generic
            _authMethod = State(initialValue: capability.authMethods.first ?? .usernamePassword)
            _displayName = State(initialValue: "")
            _serverURL = State(initialValue: preset.resolvedURL ?? "")
            _username = State(initialValue: "")
            _webDAVPreset = State(initialValue: preset)
        }
    }

    var body: some View {
        ZStack {
            hearth.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    header
                    if capability.providerType == .webdav, capability.webDAVPresets.count > 1 { webDAVPresetField }
                    if authMethods.count > 1 { authMethodField }
                    serverFields
                    credentialFields
                    if authMethod != .quickConnect { customHeaderFields }
                    if let errorMessage { errorBanner(errorMessage) }
                    actionButton
                }
                .frame(maxWidth: fieldWidth)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 70)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(capability.displayName)
                    .font(.hearthDisplay(52))
                    .foregroundStyle(hearth.text)
                Text(
                    original == nil
                        ? "Enter your server details. Use the on-screen keyboard."
                        : "Edit this server. Leave the password or token blank to keep the saved one."
                )
                .font(.title3)
                .foregroundStyle(hearth.textSecondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
        }
    }

    private var webDAVPresetField: some View {
        fieldGroup(title: "Provider") {
            HStack(spacing: 16) {
                ForEach(TVWebDAVPreset.allCases) { preset in
                    Button {
                        webDAVPreset = preset
                    } label: {
                        Text(preset.displayName)
                            .font(.body.weight(webDAVPreset == preset ? .bold : .regular))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .tint(webDAVPreset == preset ? hearth.ember : .secondary)
                }
            }
        }
    }

    private var authMethodField: some View {
        fieldGroup(title: "Sign-in method") {
            HStack(spacing: 16) {
                ForEach(authMethods) { method in
                    Button {
                        authMethod = method
                    } label: {
                        Text(method.displayName)
                            .font(.body.weight(authMethod == method ? .bold : .regular))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .tint(authMethod == method ? hearth.ember : .secondary)
                }
            }
        }
    }

    private var serverFields: some View {
        fieldGroup(title: "Server") {
            VStack(spacing: 16) {
                TextField("Display name (e.g. Home Server)", text: $displayName)
                    .textFieldStyle(.plain)
                if presetProvidesURL || isSSO || original?.mtlsEnabled == true {
                    HStack {
                        Text("Server URL")
                            .foregroundStyle(hearth.textSecondary)
                        Spacer()
                        Text(normalizedURL)
                            .foregroundStyle(hearth.text)
                    }
                    .padding(.vertical, 8)
                } else {
                    TextField(capability.serverURLPlaceholder, text: $serverURL)
                        .textFieldStyle(.plain)
                        .keyboardType(.URL)
                }
            }
        }
    }

    @ViewBuilder
    private var credentialFields: some View {
        if isSSO {
            fieldGroup(title: "Sign in") {
                Text("Signed in with single sign-on. To sign in again or change the server address, use enve on iPhone.")
                    .font(.body)
                    .foregroundStyle(hearth.textSecondary)
            }
        } else {
            switch authMethod {
            case .usernamePassword:
                fieldGroup(title: capability.credentialsOptional ? "Sign in (optional)" : "Sign in") {
                    VStack(alignment: .leading, spacing: 16) {
                        TextField(capability.usernameLabel, text: $username)
                            .textFieldStyle(.plain)
                        SecureField(secretPlaceholder(capability.passwordLabel), text: $password)
                            .textFieldStyle(.plain)
                        if original != nil, needsNewCredentials { reentryNotice }
                    }
                }
            case .token:
                fieldGroup(title: "Token") {
                    VStack(alignment: .leading, spacing: 16) {
                        SecureField(secretPlaceholder(capability.tokenLabel), text: $apiToken)
                            .textFieldStyle(.plain)
                        if original != nil, needsNewCredentials { reentryNotice }
                    }
                }
            case .quickConnect:
                fieldGroup(title: "Quick Connect") {
                    Text(
                        "Quick Connect signs you in without a password - you'll get a code to approve in your \(capability.displayName) account."
                    )
                    .font(.body)
                    .foregroundStyle(hearth.textSecondary)
                }
            }
        }
    }

    private var reentryNotice: some View {
        Text("The server or account changed, so enter its credentials again.")
            .font(.caption)
            .foregroundStyle(hearth.textSecondary)
    }

    private func secretPlaceholder(_ label: String) -> String {
        original == nil || needsNewCredentials ? label : "\(label) (leave blank to keep)"
    }

    private var customHeaderFields: some View {
        fieldGroup(title: "Custom header (optional)") {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Header name (e.g. CF-Access-Client-Id)", text: $customHeaderKey)
                    .textFieldStyle(.plain)
                SecureField("Header value", text: $customHeaderValue)
                    .textFieldStyle(.plain)
                Text(
                    original == nil
                        ? "For servers behind a reverse proxy that needs an extra header."
                        : (endpointChanged
                            ? "Enter any headers required by the new server."
                            : "Saved headers are kept. Enter a header name to add or replace one.")
                )
                .font(.caption)
                .foregroundStyle(hearth.textSecondary)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
        }
        .font(.body)
        .foregroundStyle(.red)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var actionButton: some View {
        if authMethod == .quickConnect {
            NavigationLink {
                QuickConnectView_tvOS(
                    serverURL: normalizedURL,
                    displayName: displayName.isEmpty ? capability.displayName : displayName,
                    providerType: capability.providerType,
                    customHeaders: customHeaders
                )
            } label: {
                Label("Start Quick Connect", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(normalizedURL.isEmpty)
        } else {
            Button {
                Task { await verifyAndSave() }
            } label: {
                HStack(spacing: 10) {
                    if isVerifying { ProgressView().controlSize(.small) }
                    if original == nil {
                        Text(isVerifying ? "Connecting…" : "Connect")
                    } else {
                        Text(isVerifying ? "Saving…" : "Save")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying || !canSubmit)
        }
    }

    private func fieldGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(hearth.textSecondary)
            content()
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hearth.bgElevated, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var presetProvidesURL: Bool {
        capability.providerType == .webdav && webDAVPreset.resolvedURL != nil
    }

    private var normalizedURL: String {
        if let presetURL = presetProvidesURL ? webDAVPreset.resolvedURL : nil {
            return presetURL
        }
        return Self.normalizedServerURL(serverURL)
    }

    private static func normalizedServerURL(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return "" }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        return s
    }

    private var customHeaders: [String: String]? {
        let key = customHeaderKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return [key: customHeaderValue.trimmingCharacters(in: .whitespaces)]
    }

    private var trimmedUser: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedToken: String { apiToken.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isSSO: Bool { original?.authMode == .sso }
    private var endpointChanged: Bool {
        original.map { normalizedURL != Self.normalizedServerURL($0.url) } ?? false
    }

    private var authMethods: [TVAuthMethod] {
        guard let original else { return capability.authMethods }
        guard !isSSO else { return [] }
        let stored = Self.authMethod(for: original)
        let methods = capability.authMethods.filter { $0 != .quickConnect }
        return methods.contains(stored) ? methods : methods + [stored]
    }

    private static func authMethod(for connection: ServerConnection) -> TVAuthMethod {
        switch connection.authMode {
        case .token, .sso:
            return .token
        case .usernamePassword:
            return .usernamePassword
        case .auto:
            let hasPassword = !(connection.password ?? "").isEmpty
            let hasToken = !(connection.token ?? "").isEmpty
            return hasToken && !hasPassword ? .token : .usernamePassword
        }
    }

    // Stored secrets only follow the endpoint, account and sign-in method they were issued for.
    private var needsNewCredentials: Bool {
        guard let original, !isSSO else { return false }
        if endpointChanged { return true }
        if authMethod != Self.authMethod(for: original) { return true }
        return authMethod == .usernamePassword && trimmedUser != (original.username ?? "")
    }

    private var keepsStoredSecret: Bool { original != nil && !needsNewCredentials }

    private var canSubmit: Bool {
        guard !normalizedURL.isEmpty else { return false }
        switch authMethod {
        case .usernamePassword:
            if capability.credentialsOptional { return true }
            return !trimmedUser.isEmpty && (!password.isEmpty || keepsStoredSecret)
        case .token:
            return !trimmedToken.isEmpty || keepsStoredSecret
        case .quickConnect:
            return true
        }
    }

    @MainActor
    private func verifyAndSave() async {
        errorMessage = nil
        isVerifying = true
        defer { isVerifying = false }

        var connection: ServerConnection
        if let original {
            guard let stored = appState.providerConnections.connections.first(where: { $0.id == original.id }) else {
                errorMessage = "This server is no longer saved."
                return
            }
            connection = editedConnection(from: stored)
            var renamed = stored
            renamed.name = connection.name
            if connection == renamed {
                save(connection)
                return
            }
        } else {
            let existing = appState.providerConnections.connections.first {
                $0.type == capability.providerType && $0.url == normalizedURL && ($0.username ?? "") == trimmedUser
            }
            connection = existing ?? ServerConnection(
                name: displayName.isEmpty ? capability.displayName : displayName,
                url: normalizedURL,
                type: capability.providerType
            )
            if !displayName.isEmpty { connection.name = displayName }
            connection.username = trimmedUser.isEmpty ? nil : trimmedUser
            connection.password = password.isEmpty ? nil : password
            connection.token = trimmedToken.isEmpty ? nil : trimmedToken
            if let customHeaders { connection.customHeaders = customHeaders }
        }

        guard let provider = PluginRegistry.shared.makeLibraryProvider(for: connection) else {
            errorMessage = "Couldn't create a connector for \(capability.displayName)."
            return
        }

        do {
            let ok = try await provider.validateConnection()
            guard ok else {
                errorMessage = "The server rejected those details. Check the URL and credentials."
                return
            }
            connection = provider.connection
            connection.isConnected = true
            connection.lastVerified = Date()
            save(connection)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func editedConnection(from stored: ServerConnection) -> ServerConnection {
        var connection = stored
        if !displayName.isEmpty { connection.name = displayName }
        if normalizedURL != Self.normalizedServerURL(stored.url) { connection.url = normalizedURL }
        guard let original, !isSSO else { return applyingCustomHeader(to: connection) }

        if needsNewCredentials || !password.isEmpty {
            connection.password = nil
            connection.token = nil
            connection.userId = nil
        }
        if endpointChanged {
            connection.customHeaders = nil
            connection.secretCustomHeaderNames = []
        }
        if authMethod != Self.authMethod(for: original) {
            connection.authMode = authMethod == .token ? .token : .usernamePassword
        }
        switch authMethod {
        case .usernamePassword:
            connection.username = trimmedUser.isEmpty ? nil : trimmedUser
            if !password.isEmpty { connection.password = password }
        case .token:
            if !trimmedToken.isEmpty { connection.token = trimmedToken }
        case .quickConnect:
            break
        }
        // A Home user's token outranks `token`, so it cannot survive a new token or server.
        if connection.type == .plex, needsNewCredentials || !trimmedToken.isEmpty {
            connection.plexHomeUserId = nil
            connection.plexHomeUserName = nil
            connection.plexHomeUserThumb = nil
            connection.plexHomeUserToken = nil
            connection.plexHomeUserIsManaged = nil
            connection.plexOwnerToken = nil
        }
        return applyingCustomHeader(to: connection)
    }

    private func applyingCustomHeader(to connection: ServerConnection) -> ServerConnection {
        guard let header = customHeaders?.first else { return connection }
        var connection = connection
        var headers = connection.customHeaders ?? [:]
        ServerConnection.setHeaderValue(header.value, for: header.key, in: &headers)
        connection.customHeaders = headers
        return connection
    }

    private func save(_ connection: ServerConnection) {
        if let index = appState.providerConnections.connections.firstIndex(where: { $0.id == connection.id }) {
            if original != nil, needsNewCredentials || !password.isEmpty || !trimmedToken.isEmpty {
                let keychainID = connection.id.uuidString
                if connection.token == nil { SharedKeychainStore.shared.deleteToken(forConnectionId: keychainID) }
                if connection.password == nil { SharedKeychainStore.shared.deletePassword(forConnectionId: keychainID) }
                if connection.plexHomeUserToken == nil { SharedKeychainStore.shared.deletePlexHomeUserToken(forConnectionId: keychainID) }
                if connection.plexOwnerToken == nil { SharedKeychainStore.shared.deletePlexOwnerToken(forConnectionId: keychainID) }
                if authMethod == .token, needsNewCredentials || !trimmedToken.isEmpty {
                    KeychainHelper.shared.delete("abs_refresh_\(keychainID)")
                    KeychainHelper.shared.delete("booklore_refresh_\(keychainID)")
                }
            }
            appState.providerConnections.connections[index] = connection
        } else if original == nil {
            appState.providerConnections.connections.append(connection)
        } else {
            errorMessage = "This server is no longer saved."
            return
        }

        Task { await LibraryCatalogCoordinator.shared.refreshLibrary() }
        dismiss()
    }
}
