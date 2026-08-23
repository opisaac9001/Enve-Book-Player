import Foundation

@MainActor
final class CatalogRefreshGate {
    static let shared = CatalogRefreshGate()

    private var activeProviderIds = Set<UUID>()
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    private init() {}

    func begin(providerId: UUID) async -> Bool {
        if activeProviderIds.insert(providerId).inserted {
            return true
        }

        await withCheckedContinuation { continuation in
            waiters[providerId, default: []].append(continuation)
        }
        return false
    }

    func end(providerId: UUID) {
        activeProviderIds.remove(providerId)
        let pending = waiters.removeValue(forKey: providerId) ?? []
        for continuation in pending {
            continuation.resume()
        }
    }
}
