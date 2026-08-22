import SwiftUI

struct PlexLoginView_tvOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    private let plexService = PlexService()

    enum Phase {
        case requestingPIN
        case awaitingAuth(code: String, pinID: String)
        case loadingServers
        case pickServer([PlexServer])
        case error(String)
    }

    @State private var phase: Phase = .requestingPIN
    @State private var pollTask: Task<Void, Never>?
    @State private var authToken: String?

    var body: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()

            VStack(spacing: 40) {
                switch phase {
                case .requestingPIN:
                    ProgressView("Preparing Plex sign-in…")
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)

                case .awaitingAuth(let code, _):
                    awaitingAuthView(code: code)

                case .loadingServers:
                    ProgressView("Loading your Plex servers…")
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)

                case .pickServer(let servers):
                    serverPicker(servers)

                case .error(let message):
                    errorView(message)
                }
            }
            .padding(60)
        }
        .task {
            await startPINFlow()
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    private func awaitingAuthView(code: String) -> some View {
        VStack(spacing: 32) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 96))
                .foregroundStyle(.tint)

            Text("Link your Plex account")
                .font(.system(size: 44, weight: .bold))

            VStack(spacing: 12) {
                Text("On your phone or computer, go to")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("plex.tv/link")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            VStack(spacing: 8) {
                Text("Enter this code")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 80, weight: .bold, design: .monospaced))
                    .tracking(8)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .fixedSize()
            }

            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to link…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: 1200)
    }

    private func serverPicker(_ servers: [PlexServer]) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Choose a Plex server")
                .font(.title.weight(.bold))

            if servers.isEmpty {
                Text("No Plex servers were found on your account.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(servers) { server in
                        Button {
                            Task { await saveServer(server) }
                        } label: {
                            HStack {
                                Image(systemName: "server.rack")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.name)
                                        .font(.headline)
                                    Text(server.owned ? "Your server" : "Shared with you")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 1200)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
            Text("Plex sign-in failed")
                .font(.title)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 800)
            Button("Try again") {
                Task { await startPINFlow() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @MainActor
    private func startPINFlow() async {
        pollTask?.cancel()
        phase = .requestingPIN
        do {
            let pin = try await plexService.requestPlexPin()
            phase = .awaitingAuth(code: pin.code, pinID: pin.id)
            startPolling(pinID: pin.id)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func startPolling(pinID: String) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in

            for _ in 0..<300 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                do {
                    if let token = try await plexService.checkPlexPin(id: pinID) {
                        authToken = token
                        await loadServers(token: token)
                        return
                    }
                } catch {

                    continue
                }
            }
            phase = .error("The link code expired. Please try again.")
        }
    }

    @MainActor
    private func loadServers(token: String) async {
        phase = .loadingServers
        do {
            let servers = try await plexService.getPlexServers(token: token)
            phase = .pickServer(servers)
        } catch {
            phase = .error("Signed in, but couldn't load your Plex servers: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func saveServer(_ server: PlexServer) async {

        let uri =
            server.connections.first(where: { $0.uri.hasPrefix("https://") })?.uri
            ?? server.connections.first?.uri
            ?? server.uri

        var connection = ServerConnection(
            name: server.name,
            url: uri,
            type: .plex,
            token: server.accessToken
        )
        connection.isConnected = true
        connection.lastVerified = Date()

        connection.plexOwnerToken = authToken

        if !appState.providerConnections.connections.contains(where: { $0.id == connection.id }) {
            appState.providerConnections.connections.append(connection)
        }
        Task { await LibraryCatalogCoordinator.shared.refreshLibrary() }
        dismiss()
    }
}
