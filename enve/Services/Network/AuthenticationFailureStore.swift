import Foundation

@MainActor
final class AuthenticationFailureStore {
    static let shared = AuthenticationFailureStore()

    private let defaults: UserDefaults
    private let key = "enve.authenticationFailures.v1"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var blockedConnectionIds: Set<UUID> {
        Set(defaults.stringArray(forKey: key)?.compactMap(UUID.init(uuidString:)) ?? [])
    }

    func isBlocked(connectionId: UUID) -> Bool {
        blockedConnectionIds.contains(connectionId)
    }

    func block(connectionId: UUID) {
        var ids = blockedConnectionIds
        guard ids.insert(connectionId).inserted else { return }
        defaults.set(ids.map(\.uuidString).sorted(), forKey: key)
    }

    func clear(connectionId: UUID) {
        var ids = blockedConnectionIds
        guard ids.remove(connectionId) != nil else { return }
        defaults.set(ids.map(\.uuidString).sorted(), forKey: key)
    }
}
