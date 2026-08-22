import Foundation
import Logging

struct SyncMigrationManager {

    private static let versionKey = "enve.sync.migrationVersion"
    private static let currentVersion = 1

    static func runIfNeeded() {
        let stored = UserDefaults.standard.integer(forKey: versionKey)
        guard stored < currentVersion else { return }

        AppLogger.sync.info("Running sync migration from v\(stored) to v\(currentVersion)")

        if stored < 1 {
            migrateV0ToV1()
        }

        UserDefaults.standard.set(currentVersion, forKey: versionKey)
        AppLogger.sync.info("Sync migration complete (v\(currentVersion))")
    }

    private static func migrateV0ToV1() {
        let udKey = "hardcoverApiKey"
        guard let existing = UserDefaults.standard.string(forKey: udKey), !existing.isEmpty else { return }
        KeychainHelper.shared.set(existing, key: udKey)
        UserDefaults.standard.removeObject(forKey: udKey)
        AppLogger.sync.info("Migrated Hardcover API key to Keychain")
    }
}
