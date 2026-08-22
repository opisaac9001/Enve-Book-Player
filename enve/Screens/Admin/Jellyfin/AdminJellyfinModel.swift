import Foundation
import Observation

@MainActor
@Observable
final class AdminJellyfinModel {
    let connection: ServerConnection
    private let backend: BackendConfig
    private let service = JellyfinService.shared

    var systemInfo: JellyfinSystemInfo?
    var currentUser: JellyfinAdminUser?
    var users: [JellyfinAdminUser] = []
    var plugins: [JellyfinPlugin] = []
    var scheduledTasks: [JellyfinScheduledTask] = []
    var activeSessions: [JellyfinActiveSession] = []
    var libraries: [LibraryMetadata] = []

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
        guard let token = backend.token, !token.isEmpty else {
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

        do {
            let me = try await service.getCurrentUserInfo(backend: backend)
            currentUser = me
            isAuthorized = me.isAdmin
            if !isAuthorized { return }
        } catch {
            self.error = "The server would not say who you are. Check the sign-in and try again."
            isAuthorized = false
            return
        }

        var failures: [String] = []
        do { systemInfo = try await service.getSystemInfo(backend: backend) } catch { failures.append("system info") }
        do { users = try await service.getUsers(backend: backend) } catch { failures.append("users") }
        plugins = (try? await service.getPlugins(backend: backend)) ?? plugins
        scheduledTasks = (try? await service.getScheduledTasks(backend: backend)) ?? scheduledTasks
        activeSessions = (try? await service.getActiveSessions(backend: backend)) ?? activeSessions
        libraries = (try? await service.getLibraries(backend: backend)) ?? libraries

        if !failures.isEmpty {
            error = "Some of the ledger would not open: \(failures.joined(separator: ", "))."
        }
    }

    func createUser(name: String, password: String?) async {
        await adminRun("The account was created.") {
            _ = try await self.service.createUser(name: name, password: password, backend: self.backend)
        }
    }

    func deleteUser(_ user: JellyfinAdminUser) async {
        await adminRun("The account was removed.") {
            try await self.service.deleteUser(userId: user.Id, backend: self.backend)
        }
    }

    func toggleUserDisabled(_ user: JellyfinAdminUser) async {
        let disabling = !user.isDisabled
        let policy = JellyfinPolicyUpdateRequest(isDisabled: disabling)
        await adminRun(disabling ? "The account was disabled." : "The account was enabled.") {
            try await self.service.updateUserPolicy(userId: user.Id, policy: policy, backend: self.backend)
        }
    }

    func runTask(_ task: JellyfinScheduledTask) async {
        await adminRun("\(task.displayName) has begun.") {
            try await self.service.runScheduledTask(taskId: task.id, backend: self.backend)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func restartServer() async {
        await adminRun("The server is restarting.", refresh: false) {
            try await self.service.restartServer(backend: self.backend)
        }
    }

    func refreshLibrary(libraryId: String) async {
        await adminRun("A scan has begun.") {
            try await self.service.refreshLibrary(libraryId: libraryId, backend: self.backend)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func adminExclusionKey(_ libraryId: String) -> String {
        "\(connection.id.uuidString)_\(libraryId)"
    }

    func isLibraryHidden(_ libraryId: String) -> Bool {
        LibraryDisplayPreferencesStore.shared.loadPreferences()
            .excludedLibraryIds.contains(adminExclusionKey(libraryId))
    }

    func toggleLibraryHidden(_ libraryId: String) {
        var prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
        let key = adminExclusionKey(libraryId)
        if prefs.excludedLibraryIds.contains(key) {
            prefs.excludedLibraryIds.remove(key)
        } else {
            prefs.excludedLibraryIds.insert(key)
        }
        LibraryDisplayPreferencesStore.shared.savePreferences(prefs)
    }

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
