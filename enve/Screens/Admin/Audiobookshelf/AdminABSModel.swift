import Foundation
import Observation

@MainActor
@Observable
final class AdminABSModel {
    let connection: ServerConnection
    private let backend: BackendConfig
    private let service = AudiobookshelfService.shared

    var users: [ABSUser] = []
    var onlineUsers: [ABSOnlineUser] = []
    var activeSessions: [ABSPlaySession] = []
    var libraries: [ABSLibrary] = []
    var backups: [ABSBackup] = []
    var stats: ABSStats?

    var currentUser: ABSUser?
    var isAuthorized = false
    var isLoading = false
    var hasLoaded = false
    var error: String?
    var successMessage: String?

    init(connection: ServerConnection) {
        self.connection = connection
        self.backend = BackendConfig(from: connection)!
    }

    func refreshAll() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {

            let service = self.service
            let backend = self.backend
            let fetch = Task { try await service.getMe(backend: backend) }
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                fetch.cancel()
            }
            defer { watchdog.cancel() }
            let me = try await fetch.value
            currentUser = me
            let userType = me.type.lowercased()
            isAuthorized = userType == "root" || userType == "admin"
        } catch is CancellationError {
            error = "The server did not answer in time. Check the connection and try again."
            return
        } catch {
            if case AudiobookshelfError.unauthorized = error {
                self.error = "The sign-in has expired. Reconnect to this server from its source page."
            } else {
                self.error = "Could not reach the server: \(error.localizedDescription)"
            }
            return
        }

        stats = (try? await service.getStats(backend: backend)) ?? stats
        guard isAuthorized else { return }

        var failures: [String] = []
        do { users = try await service.getUsers(backend: backend) } catch { failures.append("users") }
        do { libraries = try await service.getLibraries(backend: backend) } catch { failures.append("libraries") }
        onlineUsers = (try? await service.getOnlineUsers(backend: backend)) ?? onlineUsers
        activeSessions = (try? await service.getActiveSessions(backend: backend)) ?? activeSessions
        backups = (try? await service.getBackups(backend: backend)) ?? backups

        if !failures.isEmpty {
            error = "Some of the ledger would not open: \(failures.joined(separator: ", "))."
        }
    }

    func filesystemFolders(path: String) async throws -> [ABSFilesystemItem] {
        try await service.getFilesystemFolders(path: path, backend: backend)
    }

    func createUser(_ request: ABSUserCreateRequest) async {
        await adminRun("User created.") {
            _ = try await self.service.createUser(request: request, backend: self.backend)
        }
    }

    func updateUser(id: String, request: ABSUserUpdateRequest) async {
        await adminRun("User updated.") {
            _ = try await self.service.updateUser(id: id, request: request, backend: self.backend)
        }
    }

    func deleteUser(id: String) async {
        await adminRun("User deleted.") {
            try await self.service.deleteUser(id: id, backend: self.backend)
        }
    }

    func createLibrary(_ request: ABSLibraryRequest) async {
        await adminRun("Library created.") {
            _ = try await self.service.createLibrary(request: request, backend: self.backend)
        }
    }

    func updateLibrary(id: String, request: ABSLibraryRequest) async {
        await adminRun("Library updated.") {
            _ = try await self.service.updateLibrary(id: id, request: request, backend: self.backend)
        }
    }

    func deleteLibrary(id: String) async {
        await adminRun("Library deleted.") {
            try await self.service.deleteLibrary(id: id, backend: self.backend)
        }
    }

    func scanLibrary(id: String) async {
        await adminRun("A scan has begun.", refresh: false) {
            try await self.service.scanLibrary(id: id, backend: self.backend)
        }
    }

    func purgeLibraryCache(id: String) async {
        await adminRun("The cache was purged.", refresh: false) {
            try await self.service.purgeLibraryCache(id: id, backend: self.backend)
        }
    }

    func createBackup() async {
        await adminRun("A backup is being written.") {
            try await self.service.createBackup(backend: self.backend)
        }
    }

    func deleteBackup(filename: String) async {
        await adminRun("Backup deleted.") {
            try await self.service.deleteBackup(filename: filename, backend: self.backend)
        }
    }

    var serverURL: URL? { URL(string: backend.url) }

    private func adminRun(_ success: String, refresh: Bool = true, work: @escaping () async throws -> Void) async {
        isLoading = true
        do {
            try await work()
            successMessage = success
            if refresh { await refreshAll() }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
