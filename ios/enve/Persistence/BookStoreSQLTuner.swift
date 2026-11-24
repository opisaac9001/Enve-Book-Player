import Foundation
import SQLite3

enum BookStoreSQLTuner {
    struct Result: Sendable {
        let repairedDuplicateRows: Int
        let createdOrVerifiedIndexes: Int
    }

    private static let preflightStatements: [String] = [
        "DROP INDEX IF EXISTS ZBOOKRECORD_UNIQUEID_UNIQUE_IDX",
        "DROP INDEX IF EXISTS ZBOOKRECORD_UNIQUEID_UNIQUE_V2_IDX",
    ]

    private static let indexStatements: [String] = [
        "CREATE INDEX IF NOT EXISTS ZBOOKRECORD_UNIQUEID_IDX ON ZBOOKRECORD (ZUNIQUEID)",
        "CREATE INDEX IF NOT EXISTS ZBOOKRECORD_STABLEID_IDX ON ZBOOKRECORD (ZSTABLEID)",
        "CREATE INDEX IF NOT EXISTS ZBOOKRECORD_BOOKID_IDX ON ZBOOKRECORD (ZBOOKID)",
        "CREATE INDEX IF NOT EXISTS ZBOOKRECORD_LIBRARY_PROVIDER_ADDED_UNIQUE_IDX ON ZBOOKRECORD (ZLIBRARYID, ZPROVIDERID, ZADDEDAT, ZUNIQUEID)",
        "CREATE INDEX IF NOT EXISTS ZBOOKRECORD_MEDIATYPE_ADDED_UNIQUE_IDX ON ZBOOKRECORD (ZMEDIATYPE, ZADDEDAT, ZUNIQUEID)",
        "CREATE INDEX IF NOT EXISTS ZBOOKRECORD_MEDIATYPE_UNIQUEID_IDX ON ZBOOKRECORD (ZMEDIATYPE, ZUNIQUEID)",
        "CREATE INDEX IF NOT EXISTS ZBOOKRECORD_MEDIATYPE_LASTUPDATE_UNIQUE_IDX ON ZBOOKRECORD (ZMEDIATYPE, ZLASTUPDATE, ZUNIQUEID)",
        "CREATE INDEX IF NOT EXISTS ZBOOKRECORD_AUTHOR_MEDIATYPE_IDX ON ZBOOKRECORD (ZAUTHOR, ZMEDIATYPE)",
        "CREATE INDEX IF NOT EXISTS ZBOOKRECORD_NARRATOR_MEDIATYPE_IDX ON ZBOOKRECORD (ZNARRATOR, ZMEDIATYPE)",
        "CREATE INDEX IF NOT EXISTS ZBOOKRECORD_SOURCE_MEDIATYPE_IDX ON ZBOOKRECORD (ZSOURCE, ZMEDIATYPE)",
        "CREATE INDEX IF NOT EXISTS ZBOOKRECORD_LASTUPDATE_IDX ON ZBOOKRECORD (ZLASTUPDATE)",
        "CREATE INDEX IF NOT EXISTS ZBOOKRECORD_TITLE_IDX ON ZBOOKRECORD (ZTITLE)",
    ]

    static func apply(to storeURL: URL) throws -> Result {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return Result(repairedDuplicateRows: 0, createdOrVerifiedIndexes: 0)
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(storeURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map(errorMessage) ?? "unable to open BookStore SQLite database"
            if let db { sqlite3_close(db) }
            throw Error.sqlite(message)
        }
        defer { sqlite3_close(db) }

        try execute("PRAGMA busy_timeout = 5000", db: db)
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            let repaired = try repairMalformedIdentityRows(db: db) + repairDuplicateUniqueIds(db: db)
            for statement in preflightStatements {
                try execute(statement, db: db)
            }
            for statement in indexStatements {
                try execute(statement, db: db)
            }
            var statement: OpaquePointer?
            let hasComicColumns = sqlite3_prepare_v2(db, "SELECT ZCOMICSERIESID FROM ZBOOKRECORD LIMIT 0", -1, &statement, nil) == SQLITE_OK
            sqlite3_finalize(statement)
            if hasComicColumns {
                try execute("CREATE INDEX IF NOT EXISTS ZBOOKRECORD_COMIC_SERIES_IDX ON ZBOOKRECORD (ZPROVIDERID, ZLIBRARYID, ZCOMICSERIESID)", db: db)
            }
            try execute("COMMIT", db: db)
            return Result(repairedDuplicateRows: repaired, createdOrVerifiedIndexes: indexStatements.count + (hasComicColumns ? 1 : 0))
        } catch {
            _ = try? execute("ROLLBACK", db: db)
            throw error
        }
    }

    private static func repairDuplicateUniqueIds(db: OpaquePointer) throws -> Int {
        let sql = """
            DELETE FROM ZBOOKRECORD
            WHERE Z_PK IN (
                SELECT Z_PK FROM (
                    SELECT
                        Z_PK,
                        ROW_NUMBER() OVER (
                            PARTITION BY ZUNIQUEID
                            ORDER BY ZISDELETED ASC, ZLASTUPDATE DESC, Z_PK DESC
                        ) AS duplicateRank
                    FROM ZBOOKRECORD
                    WHERE ZUNIQUEID IS NOT NULL AND ZUNIQUEID <> ''
                )
                WHERE duplicateRank > 1
            )
            """
        try execute(sql, db: db)
        return Int(sqlite3_changes(db))
    }

    private static func repairMalformedIdentityRows(db: OpaquePointer) throws -> Int {
        let sql = """
            DELETE FROM ZBOOKRECORD
            WHERE ZUNIQUEID IS NULL
               OR ZUNIQUEID = ''
               OR ZSTABLEID IS NULL
               OR ZSTABLEID = ''
            """
        try execute(sql, db: db)
        return Int(sqlite3_changes(db))
    }

    private static func execute(_ sql: String, db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? errorMessage(db)
            if let error { sqlite3_free(error) }
            throw Error.sqlite(message)
        }
    }

    nonisolated static func downloadedAudiobookIDs(at storeURL: URL, storageKeys: Set<String>) throws -> Set<String> {
        guard !storageKeys.isEmpty else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            let message = db.map(errorMessage) ?? "unable to open BookStore SQLite database"
            if let db { sqlite3_close(db) }
            throw Error.sqlite(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        // Match download folder names without materializing every catalog record in SwiftData.
        let storageKeySQL = ["/", "\\", ":", "?", "&", "="].reduce("ZSTABLEID") {
            "replace(\($0),'\($1)','-')"
        }
        let keys = storageKeys.sorted()
        var ids = Set<String>()
        for start in stride(from: 0, to: keys.count, by: 500) {
            try Task.checkCancellation()
            let batch = keys[start..<min(start + 500, keys.count)]
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let sql = "SELECT ZSTABLEID FROM ZBOOKRECORD WHERE ZMEDIATYPE = 'audiobook' AND ZISDELETED = 0 AND \(storageKeySQL) IN (\(placeholders))"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Error.sqlite(errorMessage(db))
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, key) in batch.enumerated() {
                guard sqlite3_bind_text(statement, Int32(index + 1), key, -1, transient) == SQLITE_OK else {
                    throw Error.sqlite(errorMessage(db))
                }
            }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                try Task.checkCancellation()
                if let text = sqlite3_column_text(statement, 0) { ids.insert(String(cString: text)) }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw Error.sqlite(errorMessage(db)) }
        }
        return ids
    }

    nonisolated private static func errorMessage(_ db: OpaquePointer) -> String {
        sqlite3_errmsg(db).map(String.init(cString:)) ?? "unknown SQLite error"
    }

    enum Error: Swift.Error, LocalizedError {
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .sqlite(let message): return message
            }
        }
    }
}
