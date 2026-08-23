import AuthenticationServices
import Logging
import SwiftUI
import UIKit

private struct SourcesPlexPin: Codable {
    let id: Int
    let code: String
    let authToken: String?
}

struct SourcesPlexScreen: View {
    let onAdded: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var pin: SourcesPlexPin?
    @State private var isPollingPin = false
    @State private var authToken: String?
    @State private var ownerToken: String?
    @State private var homeUsers: [PlexHomeUser] = []
    @State private var selectedHomeUser: PlexHomeUser?
    @State private var showingUserPicker = false
    @State private var servers: [PlexServer] = []
    @State private var isBusy = false
    @State private var error: String?
    @State private var manualToken = ""
    @State private var showManualToken = false
    @State private var authSession: ASWebAuthenticationSession?

    private let clientId: String = {
        UIDevice.current.identifierForVendor?.uuidString ?? StorageService.shared.loadDeviceUUID()
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    if authToken != nil {
                        serverPicker
                    } else if isPollingPin, let pin {
                        pinCard(pin)
                    } else {
                        signInCard
                    }

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
            .sheet(isPresented: $showingUserPicker) {
                SourcesPlexUserPicker(
                    users: homeUsers,
                    ownerToken: ownerToken ?? authToken ?? "",
                    onSelect: { user, effectiveToken in
                        showingUserPicker = false
                        selectedHomeUser = user
                        authToken = effectiveToken
                        fetchServers(token: effectiveToken)
                    },
                    onSkip: {
                        showingUserPicker = false
                        if let token = authToken { fetchServers(token: token) }
                    }
                )
                .enveEnvironment()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            SourcesProviderLogo(assetName: ProviderType.plex.assetIconName, systemName: ProviderType.plex.iconName, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Overline("New source")
                Text("Plex")
                    .font(.hearthDisplay(26))
                    .foregroundStyle(hearth.text)
            }
        }
    }

    private var signInCard: some View {
        SourcesCard {
            Text("Sign in with your Plex account and we'll find your servers.")
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)

            Button {
                startPlexLogin()
            } label: {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView()
                            .tint(hearth.onEmber)
                    } else {
                        Image(systemName: "person.circle")
                            .font(.hearthUI(15, weight: .semibold))
                    }
                    Text("Sign in with Plex")
                        .font(.hearthUI(16, weight: .semibold))
                }
                .foregroundStyle(hearth.onEmber)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(hearth.ember, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .disabled(isBusy)

            Button {
                withAnimation(.snappy) { showManualToken.toggle() }
            } label: {
                Text("Use a token instead")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }

            if showManualToken {
                SourcesField(label: "X-Plex-Token", text: $manualToken, secure: true)
                QuietButton(title: "Find servers", systemImage: nil) {
                    let token = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { return }
                    ownerToken = token
                    authToken = token
                    PlexAuthStore.shared.saveToken(token)
                    fetchHomeUsers(token: token)
                }
            }
        }
    }

    private func pinCard(_ pin: SourcesPlexPin) -> some View {
        SourcesCard {
            Overline("Enter this code at plex.tv/link")
            Text(pin.code)
                .font(.hearthDisplay(56))
                .tracking(10)
                .foregroundStyle(hearth.ember)
                .frame(maxWidth: .infinity)

            QuietButton(title: "Open plex.tv", systemImage: "arrow.up.right") {
                openPlexAuthPage(code: pin.code)
            }

            HStack(spacing: 8) {
                ProgressView().tint(hearth.ember)
                Text("Waiting for you to sign in…")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }

            Button {
                isPollingPin = false
                isBusy = false
                self.pin = nil
            } label: {
                Text("Stop waiting")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusError)
            }
        }
    }

    private var serverPicker: some View {
        SourcesCard {
            Overline("Choose a server")
            if servers.isEmpty {
                if isBusy {
                    HStack(spacing: 8) {
                        ProgressView().tint(hearth.ember)
                        Text("Looking for servers…")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                } else {
                    Text("No servers found on this account.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
            } else {
                ForEach(servers) { server in
                    Button {
                        selectServer(server)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(.hearthBody.weight(.medium))
                                    .foregroundStyle(hearth.text)
                                Text("Plex Media Server")
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.hearthUI(12, weight: .semibold))
                                .foregroundStyle(hearth.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(isBusy)
                }
            }

            Button {
                authToken = nil
                ownerToken = nil
                selectedHomeUser = nil
                homeUsers = []
                servers = []
            } label: {
                Text("Switch account")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.ember)
            }
        }
    }

    private func startPlexLogin() {
        isBusy = true
        error = nil

        Task {
            do {
                let deviceName = UIDevice.current.name
                let model = UIDevice.current.model
                let systemVersion = UIDevice.current.systemVersion

                var components = URLComponents(string: "https://plex.tv/api/v2/pins")!
                components.queryItems = [
                    URLQueryItem(name: "strong", value: "true"),
                    URLQueryItem(name: "X-Plex-Product", value: "Enve"),
                    URLQueryItem(name: "X-Plex-Client-Identifier", value: clientId),
                    URLQueryItem(name: "X-Plex-Device", value: deviceName),
                    URLQueryItem(name: "X-Plex-Platform", value: "iOS"),
                    URLQueryItem(name: "X-Plex-Platform-Version", value: systemVersion),
                    URLQueryItem(name: "X-Plex-Model", value: model),
                ]
                guard let requestURL = components.url else { throw ProviderError.invalidURL }

                var request = URLRequest(url: requestURL)
                request.httpMethod = "POST"
                request.setValue("Enve", forHTTPHeaderField: "X-Plex-Product")
                request.setValue(clientId, forHTTPHeaderField: "X-Plex-Client-Identifier")
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                let (data, _) = try await URLSession.shared.data(for: request)
                let pinResponse = try JSONDecoder().decode(SourcesPlexPin.self, from: data)

                pin = pinResponse
                isPollingPin = true
                openPlexAuthPage(code: pinResponse.code)

                try await pollPin(id: pinResponse.id)
            } catch {
                self.error = "Couldn't start the Plex sign-in: \(error.localizedDescription)"
                self.isBusy = false
            }
        }
    }

    private func openPlexAuthPage(code: String) {
        let deviceName =
            UIDevice.current.name
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let model =
            UIDevice.current.model
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString =
            "https://app.plex.tv/auth#?clientID=\(clientId)&code=\(code)&product=Enve&device=\(deviceName)&platform=iOS&model=\(model)"
        guard let url = URL(string: urlString) else { return }

        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in }
        session.presentationContextProvider = OAuthManager.shared
        session.prefersEphemeralWebBrowserSession = false
        if session.start() {
            authSession = session
        } else {
            UIApplication.shared.open(url)
        }
    }

    private func pollPin(id: Int) async throws {
        let startTime = Date()
        while isPollingPin {
            if Date().timeIntervalSince(startTime) > 1800 {
                error = "Sign-in timed out. Try again."
                isPollingPin = false
                isBusy = false
                return
            }

            guard let url = URL(string: "https://plex.tv/api/v2/pins/\(id)?includeClient=1") else {
                error = "Couldn't reach plex.tv."
                isPollingPin = false
                isBusy = false
                return
            }
            var request = URLRequest(url: url)
            request.setValue(clientId, forHTTPHeaderField: "X-Plex-Client-Identifier")
            request.setValue("Enve", forHTTPHeaderField: "X-Plex-Product")
            request.setValue("1.0", forHTTPHeaderField: "X-Plex-Version")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, _) = try await URLSession.shared.data(for: request)
            let status = try JSONDecoder().decode(SourcesPlexPin.self, from: data)

            if let token = status.authToken {
                ownerToken = token
                authToken = token
                isPollingPin = false
                PlexAuthStore.shared.saveToken(token)
                fetchHomeUsers(token: token)
                return
            }

            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func fetchHomeUsers(token: String) {
        isBusy = true
        Task {
            do {
                let users = try await PlexService().getPlexHomeUsers(token: token)
                homeUsers = users
                isBusy = false
                if users.count > 1 {
                    showingUserPicker = true
                } else {
                    fetchServers(token: token)
                }
            } catch {
                AppLogger.library.error("Could not fetch Plex Home users: \(error.localizedDescription). Continuing as owner")
                isBusy = false
                fetchServers(token: token)
            }
        }
    }

    private func fetchServers(token: String) {
        isBusy = true
        Task {
            do {
                let found = try await PlexService().getPlexServers(
                    token: token,
                    ownerToken: ownerToken,
                    switchedUserId: selectedHomeUser?.isAdmin == true ? nil : selectedHomeUser?.id
                )
                servers = found
                isBusy = false
            } catch {
                self.error = "Couldn't find servers: \(error.localizedDescription)"
                self.isBusy = false
            }
        }
    }

    private func selectServer(_ server: PlexServer) {
        isBusy = true
        error = nil

        Task {
            let token = server.accessToken
            let service = PlexService()

            guard let workingURL = await service.findBestConnection(server: server) else {
                self.error =
                    "Couldn't reach \(server.name). Check that remote access is enabled or that this Mac can reach the server's local network."
                self.isBusy = false
                return
            }

            do {
                try await verifyAndAdd(name: server.name, url: workingURL, serverToken: token)
            } catch {
                self.error = "Couldn't add \(server.name): \(error.localizedDescription)"
                self.isBusy = false
            }
        }
    }

    private func verifyAndAdd(name: String, url: String, serverToken: String) async throws {
        var temp = ServerConnection(
            name: name,
            url: url,
            type: .plex,
            token: serverToken,
            isConnected: false,
            authMode: .auto
        )
        temp.plexOwnerToken = ownerToken ?? (selectedHomeUser?.isAdmin == true ? serverToken : nil)
        if let homeUser = selectedHomeUser, !homeUser.isAdmin {
            temp.plexHomeUserId = homeUser.id
            temp.plexHomeUserName = homeUser.displayName
            temp.plexHomeUserThumb = homeUser.thumb
            temp.plexHomeUserToken = serverToken
            temp.plexHomeUserIsManaged = homeUser.isManaged
        }

        let (isValid, validated) = try await appState.validateConnection(temp)
        guard isValid else {
            error = "Connection failed. Please try again."
            isBusy = false
            return
        }

        var final = validated
        final.isConnected = true
        final.lastVerified = Date()
        SourcesFinalizer.upsert(final, into: appState)
        PlatformHaptics.notification(.success)
        Task { await SourcesFinalizer.importAndSync(providerId: final.id) }
        onAdded()
    }
}

struct SourcesPlexUserPicker: View {
    let users: [PlexHomeUser]
    let ownerToken: String
    let onSelect: (PlexHomeUser, String) -> Void
    let onSkip: () -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var selectedUser: PlexHomeUser?
    @State private var pinTargetUser: PlexHomeUser?
    @State private var showingPinPrompt = false
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Overline("Plex Home")
                        Text("Who's listening?")
                            .font(.hearthDisplay(26))
                            .foregroundStyle(hearth.text)
                        Text("Each user keeps their own progress on the server.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                    }

                    if let error { SourcesErrorText(message: error) }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(sortedUsers) { user in
                            Button {
                                selectUser(user)
                            } label: {
                                SourcesPlexUserCard(
                                    user: user,
                                    isSelected: selectedUser?.id == user.id,
                                    isLoading: isLoading && selectedUser?.id == user.id
                                )
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .background(HearthBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { onSkip() }
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            .sheet(isPresented: $showingPinPrompt) {
                SourcesPlexPinEntry(
                    userName: pinTargetUser?.displayName ?? "User",
                    onSubmit: { pin in
                        showingPinPrompt = false
                        if let user = pinTargetUser { performSwitch(user: user, pin: pin) }
                    },
                    onCancel: {
                        showingPinPrompt = false
                        isLoading = false
                    }
                )
                .presentationDetents([.height(300)])
                .enveEnvironment()
            }
        }
    }

    private var sortedUsers: [PlexHomeUser] {
        users.sorted { a, b in
            if a.isAdmin != b.isAdmin { return a.isAdmin }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private func selectUser(_ user: PlexHomeUser) {
        guard !isLoading else { return }
        error = nil
        selectedUser = user

        if user.isAdmin {
            onSelect(user, ownerToken)
            return
        }
        if user.hasPin {
            pinTargetUser = user
            showingPinPrompt = true
            return
        }
        performSwitch(user: user, pin: nil)
    }

    private func performSwitch(user: PlexHomeUser, pin: String?) {
        isLoading = true
        error = nil

        Task {
            do {
                let response = try await PlexService().switchPlexHomeUser(
                    userId: user.id,
                    token: ownerToken,
                    pin: pin
                )
                guard let switchedToken = response.authToken else {
                    error = "Couldn't switch to \(user.displayName)."
                    isLoading = false
                    return
                }
                isLoading = false
                onSelect(user, switchedToken)
            } catch {
                self.error = "Switch failed: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}

private struct SourcesPlexUserCard: View {
    let user: PlexHomeUser
    let isSelected: Bool
    let isLoading: Bool

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if let thumb = user.thumb, let url = URL(string: thumb) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            avatarPlaceholder
                        }
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())
                } else {
                    avatarPlaceholder
                }
                if isLoading {
                    ProgressView().tint(hearth.ember)
                }
                if user.hasPin && !user.isAdmin {
                    Image(systemName: "lock.fill")
                        .font(.hearthUI(9))
                        .foregroundStyle(hearth.text)
                        .padding(4)
                        .background(Circle().fill(hearth.bgElevated))
                        .offset(x: 22, y: 22)
                }
            }

            VStack(spacing: 2) {
                Text(user.displayName)
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                Text(user.isAdmin ? "Owner" : (user.isManaged ? "Managed" : "Home"))
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(isSelected ? hearth.ember : hearth.hairline, lineWidth: isSelected ? 1.5 : 1)
                }
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(hearth.bg)
            .frame(width: 60, height: 60)
            .overlay {
                Text(String(user.displayName.prefix(1)).uppercased())
                    .font(.hearthDisplay(22))
                    .foregroundStyle(hearth.textSecondary)
            }
    }
}

private struct SourcesPlexPinEntry: View {
    let userName: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.hearth) private var hearth
    @State private var pin = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Overline("This user has a PIN")
            Text(userName)
                .font(.hearthDisplay(22))
                .foregroundStyle(hearth.text)

            SecureField("PIN", text: $pin)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: Hearth.scaled(22), weight: .semibold, design: .monospaced))
                .foregroundStyle(hearth.text)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(hearth.bgElevated)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(hearth.hairline, lineWidth: 1)
                        }
                }
                .padding(.horizontal, 40)
                .focused($isFocused)

            HStack(spacing: 12) {
                QuietButton(title: "Cancel", systemImage: nil) { onCancel() }
                EmberButton(title: "Continue", systemImage: nil, tint: nil) { onSubmit(pin) }
                    .disabled(pin.isEmpty)
                    .opacity(pin.isEmpty ? 0.5 : 1)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HearthBackground())
        .onAppear { isFocused = true }
    }
}
