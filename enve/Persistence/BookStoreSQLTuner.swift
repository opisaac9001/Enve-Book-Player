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
            try execute("COMMIT", db: db)
            return Result(repairedDuplicateRows: repaired, createdOrVerifiedIndexes: indexStatements.count)
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

    private static func errorMessage(_ db: OpaquePointer) -> String {
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
