import Foundation
import SwiftData

enum BookStoreMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [BookStoreSchemaV1.self, BookStoreSchemaV2.self]
    }

    // V2 only adds optional comic catalog columns; providers repopulate them on the next catalog refresh.
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: BookStoreSchemaV1.self, toVersion: BookStoreSchemaV2.self)]
    }
}
