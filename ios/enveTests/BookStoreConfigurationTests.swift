import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
struct BookStoreConfigurationTests {
    @Test(.enabled(if: ProfileSwitchCoordinator.supportsMultipleProfileStorage))
    func simultaneousProfileContainersSaveToTheirOwnStores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let configuration = ModelConfiguration("BookStore", schema: schema, url: root.appendingPathComponent("BookStore.sqlite"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, migrationPlan: BookStoreMigrationPlan.self, configurations: [configuration])
        _ = try BookStoreSQLTuner.apply(to: configuration.url)
        let book = Book(id: "direct", title: "Direct", source: .local, backendId: "fixture", providerId: UUID(), libraryId: "fixture")
        let repository = SwiftDataBookStore(container: container)
        let secondSchema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let secondConfiguration = ModelConfiguration("BookStoreSecond", schema: secondSchema, url: root.appendingPathComponent("Second.sqlite"), cloudKitDatabase: .none)
        let second = try ModelContainer(for: secondSchema, migrationPlan: BookStoreMigrationPlan.self, configurations: [secondConfiguration])
        let secondRepository = SwiftDataBookStore(container: second)
        await secondRepository.upsertBooks([book])
        await repository.upsertBooks([book])
        let other = Book(id: "worker", title: "Worker", source: .local, backendId: "fixture", providerId: UUID(), libraryId: "fixture")
        await repository.upsertBooks([other])
        #expect(await repository.bookCount() == 2)
        #expect(await secondRepository.bookCount() == 1)
    }
}
