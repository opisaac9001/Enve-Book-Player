import Foundation
import Logging
import SwiftData

@MainActor
final class BookStoreManager {
    static let shared = BookStoreManager()

    let repository: BookStoreRepository

    private let container: ModelContainer
    private static let migrationVersionKey = "enve.bookstore.migrationVersion"
    private static let currentMigrationVersion = 1

    private static let appliedSchemaVersionKey = "enve.bookstore.appliedSchemaVersion"

    static var currentSchemaVersionString: String { BookStoreSchemaV1.versionString }

    static var lastAppliedSchemaVersionString: String? {
        UserDefaults.standard.string(forKey: appliedSchemaVersionKey)
    }

    private static var storeURL: URL {
        URL.documentsDirectory.appendingPathComponent("BookStore.sqlite")
    }

    private static func removeStoreFiles() {
        let fm = FileManager.default
        let basePath = storeURL.path
        let urls = [
            storeURL,
            URL(fileURLWithPath: basePath + "-wal"),
            URL(fileURLWithPath: basePath + "-shm"),
        ]
        for url in urls where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                AppLogger.general.error(
                    "BookStore removal failed \(DiagnosticLogSanitizer.fileDescriptor(for: url)): \(error)"
                )
            }
        }
    }

    private init() {
        let schema = Schema(versionedSchema: BookStoreSchemaV1.self)
        let config = ModelConfiguration(
            "BookStore",
            schema: schema,
            url: Self.storeURL,
            cloudKitDatabase: .none
        )

        var resolvedContainer: ModelContainer
        var outcome: StoreHealthState = .healthy
        var backupLocation: URL? = nil
        do {
            resolvedContainer = try ModelContainer(
                for: schema,
                migrationPlan: BookStoreMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            AppLogger.general.error("BookStore: persistent store failed, resetting: \(error)")

            backupLocation = StoreBackup.backup(storeURL: Self.storeURL, label: "BookStore")
            Self.removeStoreFiles()
            do {
                resolvedContainer = try ModelContainer(
                    for: schema,
                    migrationPlan: BookStoreMigrationPlan.self,
                    configurations: [config]
                )
                outcome = .recoveredFromBackup
            } catch {
                AppLogger.general.error("BookStore: fallback to in-memory: \(error)")
                let memConfig = ModelConfiguration(
                    "BookStoreInMemory",
                    schema: schema,
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                )
                do {
                    resolvedContainer = try ModelContainer(
                        for: schema,
                        migrationPlan: BookStoreMigrationPlan.self,
                        configurations: [memConfig]
                    )
                    outcome = .runningInMemory
                } catch {
                    AppLogger.general.error("BookStore: in-memory fallback also failed: \(error); using default schema container")
                    do {
                        resolvedContainer = try ModelContainer(
                            for: schema,
                            migrationPlan: BookStoreMigrationPlan.self
                        )
                        outcome = .rebuildRequired
                    } catch {
                        AppLogger.general.error("BookStore: emergency default container failed: \(error)")

                        fatalError("BookStore: SwiftData unavailable on this device: \(error)")
                    }
                }
            }
        }
        self.container = resolvedContainer
        self.repository = SwiftDataBookStore(container: resolvedContainer)

        if outcome != .runningInMemory {
            do {
                let tuning = try BookStoreSQLTuner.apply(to: Self.storeURL)
                if tuning.repairedDuplicateRows > 0 {
                    AppLogger.general.warning(
                        "BookStore: repaired \(tuning.repairedDuplicateRows) duplicate uniqueId row(s) before applying indexes"
                    )
                }
                AppLogger.general.info("BookStore: verified \(tuning.createdOrVerifiedIndexes) SQLite index(es)")
            } catch {
                AppLogger.general.error("BookStore: SQL index tuning failed: \(error.localizedDescription)")
            }
        }

        let previous = Self.lastAppliedSchemaVersionString
        let current = Self.currentSchemaVersionString
        let migrated = previous != nil && previous != current
        if previous != current {
            AppLogger.general.info("BookStore: schema version \(previous ?? "<none>") → \(current) - migration applied")
            UserDefaults.standard.set(current, forKey: Self.appliedSchemaVersionKey)
        }

        let publishedOutcome = outcome
        let publishedBackup = backupLocation
        let publishedMigrated = migrated
        let publishedPrevious = previous
        StoreHealth.shared.state = publishedOutcome
        StoreHealth.shared.lastBackupLocation = publishedBackup
        StoreHealth.shared.schemaMigrationOccurred = publishedMigrated
        StoreHealth.shared.previousSchemaVersion = publishedPrevious
        StoreHealth.shared.hasAcknowledged = false
    }

    var needsLegacyImport: Bool {
        UserDefaults.standard.integer(forKey: Self.migrationVersionKey) < Self.currentMigrationVersion
    }

    func runLegacyImportIfNeeded(allBooks: [Book], hiddenStableIds: Set<String>, deletedStableIds: Set<String>) async {
        guard needsLegacyImport else { return }
        guard !allBooks.isEmpty else { return }

        AppLogger.general.info("BookStore: starting legacy import of \(allBooks.count) books")
        await repository.importLegacyBooks(allBooks, hiddenStableIds: hiddenStableIds, deletedStableIds: deletedStableIds)
        UserDefaults.standard.set(Self.currentMigrationVersion, forKey: Self.migrationVersionKey)
        AppLogger.general.info("BookStore: legacy import complete, migration version set to \(Self.currentMigrationVersion)")
    }

    func resetStore() {
        Self.removeStoreFiles()
        UserDefaults.standard.removeObject(forKey: Self.migrationVersionKey)
    }
}
