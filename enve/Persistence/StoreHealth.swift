import Foundation
import Observation

enum StoreHealthState: Sendable, Hashable {

    case healthy

    case recoveredFromBackup

    case runningInMemory

    case rebuildRequired
}

@Observable
@MainActor
final class StoreHealth {
    static let shared = StoreHealth()

    var state: StoreHealthState = .healthy

    var lastBackupLocation: URL? = nil

    var schemaMigrationOccurred: Bool = false

    var previousSchemaVersion: String? = nil

    var hasAcknowledged: Bool = false

    private init() {}

    func acknowledge() {
        hasAcknowledged = true
    }
}
