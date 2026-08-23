import Foundation

struct ProviderSyncResult {
    let pulled: Int
    let pushed: Int

    static let zero = ProviderSyncResult(pulled: 0, pushed: 0)
}

@MainActor
protocol ProviderSyncStrategy: AnyObject {

    var id: String { get }

    var displayName: String { get }

    func sync(force: Bool, launchOptimized: Bool) async -> ProviderSyncResult
}
