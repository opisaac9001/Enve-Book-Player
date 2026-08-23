import Foundation
import Observation

@MainActor
@Observable
final class AdminPlexModel {
    let connection: ServerConnection
    private let service = PlexService()

    var serverInfo: PlexServerInfo?
    var activeSessions: [PlexActiveSession] = []
    var librarySections: [PlexLibrarySection] = []

    var sharedUsers: [PlexManagedUser] = []

    var isOwner = false
    var isLoading = false
    var hasLoaded = false
    var error: String?
    var successMessage: String?

    private var token: String? { connection.token }

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func refreshAll() async {
        guard let token, !token.isEmpty else {
            error = "There is no sign-in for this server. Reconnect it from its source page."
            hasLoaded = true
            return
        }

        isLoading = true
        error = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        var failures: [String] = []

        do {
            serverInfo = try await service.getServerIdentity(serverUrl: connection.url, token: token)
            do {
                let servers = try await service.getPlexServers(token: token)
                if let machineId = serverInfo?.machineIdentifier {
                    isOwner = servers.contains { $0.owned && $0.id == machineId }
                } else {
                    isOwner = servers.contains { server in
                        server.owned && server.connections.contains { $0.uri.contains(connection.url) }
                    }
                }
            } catch {
                isOwner = false
            }
        } catch {
            failures.append("server identity")
            isOwner = false
        }

        activeSessions = (try? await service.getActiveSessions(serverUrl: connection.url, token: token)) ?? activeSessions

        do {
            librarySections = try await service.getAdminLibrarySections(serverUrl: connection.url, token: token)
        } catch {
            failures.append("libraries")
        }

        sharedUsers = (try? await service.getSharedUsers(token: token)) ?? sharedUsers

        if !failures.isEmpty {
            error = "Some of the ledger would not open: \(failures.joined(separator: ", "))."
        }
    }

    func refreshSessions() async {
        guard let token, !token.isEmpty else { return }
        if let sessions = try? await service.getActiveSessions(serverUrl: connection.url, token: token) {
            activeSessions = sessions
        }
    }

    func refreshLibrary(sectionKey: String) async {
        await adminRun("A scan has begun.", refresh: false) { token in
            try await self.service.refreshLibrary(serverUrl: self.connection.url, token: token, sectionKey: sectionKey)
        }
    }

    func emptyTrash(sectionKey: String) async {
        await adminRun("The trash was emptied.", refresh: false) { token in
            try await self.service.emptyTrash(serverUrl: self.connection.url, token: token, sectionKey: sectionKey)
        }
    }

    func optimizeDatabase() async {
        await adminRun("The database is being tidied.", refresh: false) { token in
            try await self.service.optimizeDatabase(serverUrl: self.connection.url, token: token)
        }
    }

    func emptyAllTrash() async {
        await adminRun("Every library's trash was emptied.", refresh: false) { token in
            for section in self.librarySections {
                try await self.service.emptyTrash(serverUrl: self.connection.url, token: token, sectionKey: section.key)
            }
        }
    }

    func terminateSession(_ session: PlexActiveSession) async {
        await adminRun("The stream was ended.") { token in
            try await self.service.terminateSession(
                serverUrl: self.connection.url,
                token: token,
                sessionId: session.sessionKey ?? session.id
            )
        }
    }

    func removeSharedUser(_ user: PlexManagedUser) async {
        await adminRun("\(user.displayName) no longer has access.") { token in
            try await self.service.removeSharedUser(token: token, userId: user.id)
        }
    }

    func inviteUser(
        email: String,
        selectedLibraries: [String],
        allowSync: Bool,
        allowCameraUpload: Bool,
        allowChannels: Bool
    ) async {
        guard let serverId = serverInfo?.machineIdentifier, !serverId.isEmpty else {
            error = "The server has not told us its identity yet. Refresh and try again."
            return
        }
        await adminRun("An invitation went out to \(email).") { token in
            try await self.service.inviteUserToServer(
                token: token,
                serverId: serverId,
                email: email,
                sectionIds: selectedLibraries,
                allowSync: allowSync,
                allowCameraUpload: allowCameraUpload,
                allowChannels: allowChannels
            )
        }
    }

    private func adminRun(
        _ success: String,
        refresh: Bool = true,
        work: @escaping (String) async throws -> Void
    ) async {
        guard let token, !token.isEmpty else { return }
        isLoading = true
        do {
            try await work(token)
            successMessage = success
            if refresh { await refreshAll() }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
