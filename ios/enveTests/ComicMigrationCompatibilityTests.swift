import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
struct ComicMigrationCompatibilityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_COMIC_MIGRATION_BASELINE"] != nil))
    func opensAnOriginalStoreWithoutRecoveryOrDataLoss() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ENVE_COMIC_MIGRATION_BASELINE"])
        let source = URL(fileURLWithPath: path)
        let destination = source.deletingLastPathComponent().appendingPathComponent("comic-migration-verified.sqlite")
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: destination.path + suffix)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        try fm.copyItem(at: source, to: destination)
        let manifest = try JSONDecoder().decode(
            Baseline.self,
            from: Data(contentsOf: source.deletingPathExtension().appendingPathExtension("manifest.json"))
        )
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, url: destination, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: schema, migrationPlan: BookStoreMigrationPlan.self, configurations: [configuration]
        )
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<BookRecord>()) == manifest.count)
        try context.save()
    }

    private struct Baseline: Decodable {
        let count: Int
    }
}
