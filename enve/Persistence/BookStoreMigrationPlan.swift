import Foundation
import SwiftData

enum BookStoreMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [BookStoreSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
