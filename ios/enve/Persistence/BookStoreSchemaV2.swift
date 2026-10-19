import Foundation
import SwiftData

enum BookStoreSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var versionString: String { "2.0.0" }

    static var models: [any PersistentModel.Type] {
        [
            BookRecord.self,
            MediaProgressRecord.self,
            LinkedBookPairRecord.self,
            BookmarkRecord.self,
            AnnotationRecord.self,
            ChapterCacheRecord.self,
            VocabEntryRecord.self,
            LibrarySyncCursor.self,
        ]
    }
}
