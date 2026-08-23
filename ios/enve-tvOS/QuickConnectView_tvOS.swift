import SwiftUI

struct QuickConnectView_tvOS: View {
    let serverURL: String
    let displayName: String
    let providerType: ProviderType
    let customHeaders: [String: String]?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    private let quickConnect = JellyfinQuickConnectService.shared

    enum Phase {
        case starting
        case awaitingApproval(code: String, secret: String)
        case finishing
        case error(String)
    }

    @State private var phase: Phase = .starting
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color(white: 0.11).ignoresSafeArea()

            VStack(spacing: 40) {
                switch phase {
                case .starting:
                    ProgressView("Starting Quick Connect…")
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)
                case .awaitingApproval(let code, _):
                    awaitingView(code: code)
                case .finishing:
                    ProgressView("Signing in…")
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)
                case .error(let message):
                    errorView(message)
                }
            }
            .padding(60)
        }
        .navigationTitle("Quick Connect")
        .task { await start() }
        .onDisappear { pollTask?.cancel() }
    }

    private func awaitingView(code: String) -> some View {
        VStack(spacing: 32) {
            Image(systemName: "qrcode")
                .font(.system(size: 88))
                .foregroundStyle(.tint)

            Text("Approve this device")
                .font(.system(size: 44, weight: .bold))

            VStack(spacing: 12) {
                Text("In your Jellyfin account - on a phone or computer - open")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Settings › Quick Connect")
                    .font(.title3.weight(.semibold))
            }

            VStack(spacing: 8) {
                Text("Enter this code")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 76, weight: .bold, design: .monospaced))
                    .tracking(8)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .fixedSize()
            }

            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Waiting for approval…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: 1200)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
            Text("Quick Connect failed")
                .font(.title)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 800)
            Button("Try again") {
                Task { await start() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @MainActor
    private func start() async {
        pollTask?.cancel()
        phase = .starting
        do {
            let result = try await quickConnect.initiateQuickConnect(
                serverURL: serverURL,
                customHeaders: customHeaders ?? [:]
            )
            phase = .awaitingApproval(code: result.Code, secret: result.Secret)
            startPolling(secret: result.Secret)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func startPolling(secret: String) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            do {

                _ = try await quickConnect.pollForAuthentication(
                    secret: secret,
                    serverURL: serverURL,
                    customHeaders: customHeaders ?? [:],
                    cancellationCheck: { Task.isCancelled }
                )
                if Task.isCancelled { return }
                await finishLogin(secret: secret)
            } catch {
                if Task.isCancelled { return }
                phase = .error(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func finishLogin(secret: String) async {
        phase = .finishing
        do {
            let auth = try await quickConnect.authenticateWithQuickConnect(
                secret: secret,
                serverURL: serverURL,
                customHeaders: customHeaders ?? [:]
            )
            var connection = ServerConnection(
                name: displayName,
                url: serverURL,
                type: providerType,
                username: auth.userName,
                token: auth.token,
                userId: auth.userId
            )
            connection.customHeaders = customHeaders
            connection.isConnected = true
            connection.lastVerified = Date()

            if !appState.providerConnections.connections.contains(where: { $0.id == connection.id }) {
                appState.providerConnections.connections.append(connection)
            }
            Task { await LibraryCatalogCoordinator.shared.refreshLibrary() }
            dismiss()
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
