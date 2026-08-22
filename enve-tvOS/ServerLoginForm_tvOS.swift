import SwiftUI

struct ServerLoginForm_tvOS: View {
    let backend: AddServerView_tvOS.Backend

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    private var capability: TVServerCapability { TVServerCapability.forBackend(backend) }

    @State private var authMethod: TVAuthMethod = .usernamePassword
    @State private var displayName: String = ""
    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var apiToken: String = ""
    @State private var webDAVPreset: TVWebDAVPreset = .generic
    @State private var customHeaderKey: String = ""
    @State private var customHeaderValue: String = ""

    @State private var isVerifying = false
    @State private var errorMessage: String?

    private let fieldWidth: CGFloat = 1100

    var body: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    header
                    if capability.providerType == .webdav, capability.webDAVPresets.count > 1 { webDAVPresetField }
                    if capability.authMethods.count > 1 { authMethodField }
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
        .onAppear {
            authMethod = capability.authMethods.first ?? .usernamePassword
            if let preset = capability.webDAVPresets.first {
                webDAVPreset = preset
                if let url = preset.resolvedURL, serverURL.isEmpty {
                    serverURL = url
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(capability.displayName)
                    .font(.system(size: 52, weight: .bold))
                Text("Enter your server details. Use the on-screen keyboard.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
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
                    .tint(webDAVPreset == preset ? .accentColor : .secondary)
                }
            }
        }
    }

    private var authMethodField: some View {
        fieldGroup(title: "Sign-in method") {
            HStack(spacing: 16) {
                ForEach(capability.authMethods) { method in
                    Button {
                        authMethod = method
                    } label: {
                        Text(method.displayName)
                            .font(.body.weight(authMethod == method ? .bold : .regular))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .tint(authMethod == method ? .accentColor : .secondary)
                }
            }
        }
    }

    private var serverFields: some View {
        fieldGroup(title: "Server") {
            VStack(spacing: 16) {
                TextField("Display name (e.g. Home Server)", text: $displayName)
                    .textFieldStyle(.plain)
                if presetProvidesURL {
                    HStack {
                        Text("Server URL")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(webDAVPreset.resolvedURL ?? "")
                            .foregroundStyle(.primary)
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
        switch authMethod {
        case .usernamePassword:
            fieldGroup(title: capability.credentialsOptional ? "Sign in (optional)" : "Sign in") {
                VStack(spacing: 16) {
                    TextField(capability.usernameLabel, text: $username)
                        .textFieldStyle(.plain)
                    SecureField(capability.passwordLabel, text: $password)
                        .textFieldStyle(.plain)
                }
            }
        case .token:
            fieldGroup(title: "Token") {
                TextField(capability.tokenLabel, text: $apiToken)
                    .textFieldStyle(.plain)
            }
        case .quickConnect:
            fieldGroup(title: "Quick Connect") {
                Text(
                    "Quick Connect signs you in without a password - you'll get a code to approve in your \(capability.displayName) account."
                )
                .font(.body)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var customHeaderFields: some View {
        fieldGroup(title: "Custom header (optional)") {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Header name (e.g. CF-Access-Client-Id)", text: $customHeaderKey)
                    .textFieldStyle(.plain)
                TextField("Header value", text: $customHeaderValue)
                    .textFieldStyle(.plain)
                Text("For servers behind a reverse proxy that needs an extra header.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text(isVerifying ? "Connecting…" : "Connect")
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
                .foregroundStyle(.secondary)
            content()
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var presetProvidesURL: Bool {
        capability.providerType == .webdav && webDAVPreset.resolvedURL != nil
    }

    private var normalizedURL: String {
        if let presetURL = presetProvidesURL ? webDAVPreset.resolvedURL : nil {
            return presetURL
        }
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private var canSubmit: Bool {
        guard !normalizedURL.isEmpty else { return false }
        switch authMethod {
        case .usernamePassword:
            if capability.credentialsOptional { return true }
            return !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        case .token:
            return !apiToken.trimmingCharacters(in: .whitespaces).isEmpty
        case .quickConnect:
            return true
        }
    }

    @MainActor
    private func verifyAndSave() async {
        errorMessage = nil
        isVerifying = true
        defer { isVerifying = false }

        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)

        var connection = ServerConnection(
            name: displayName.isEmpty ? capability.displayName : displayName,
            url: normalizedURL,
            type: capability.providerType,
            username: trimmedUser.isEmpty ? nil : trimmedUser,
            password: password.isEmpty ? nil : password,
            token: trimmedToken.isEmpty ? nil : trimmedToken
        )
        connection.customHeaders = customHeaders

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

            if !appState.providerConnections.connections.contains(where: { $0.id == connection.id }) {
                appState.providerConnections.connections.append(connection)
            }

            Task { await LibraryCatalogCoordinator.shared.refreshLibrary() }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
