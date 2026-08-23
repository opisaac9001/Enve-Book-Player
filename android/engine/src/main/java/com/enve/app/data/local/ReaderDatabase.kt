package com.enve.app.data.local

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.enve.app.data.metadata.MatchedBookMetadata
import com.enve.app.data.metadata.MatchedBookMetadataDao
import com.enve.app.data.reader.LayoutPreset
import com.enve.app.data.reader.LayoutPresetDao
import com.enve.app.data.reader.EpubBridgeCheckpointDao
import com.enve.app.data.reader.EpubBridgeCheckpointEntity
import com.enve.app.playback.PlaybackQueueDao
import com.enve.app.playback.PlaybackQueueEntry
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.BookExtras
import com.enve.core.data.local.BookExtrasDao
import com.enve.core.data.local.BookMetadataOverride
import com.enve.core.data.local.BookMetadataOverrideDao
import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.CachedLibrary
import com.enve.core.data.local.CustomSmartCollection
import com.enve.core.data.local.CustomSmartCollectionDao
import com.enve.core.data.local.LibraryCacheDao
import com.enve.core.data.local.LinkedBookPair
import com.enve.core.data.local.LinkedBookPairDao
import com.enve.core.data.local.PendingProgressPush
import com.enve.core.data.local.PendingProgressPushDao
import com.enve.core.data.local.UserCollection
import com.enve.core.data.local.UserCollectionBook
import com.enve.core.data.local.UserCollectionDao
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.model.ReaderAnnotationDao

val MIGRATION_1_2 = object : Migration(1, 2) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS layout_presets (
                id TEXT NOT NULL PRIMARY KEY,
                name TEXT NOT NULL,
                theme TEXT NOT NULL DEFAULT 'DARK',
                fontFamily TEXT NOT NULL DEFAULT 'SERIF',
                fontSize REAL NOT NULL DEFAULT 1.0,
                lineHeight REAL NOT NULL DEFAULT 1.4,
                pageMargins REAL NOT NULL DEFAULT 1.0,
                wordSpacing REAL NOT NULL DEFAULT 0.0,
                letterSpacing REAL NOT NULL DEFAULT 0.0,
                fontWeight REAL NOT NULL DEFAULT 1.0,
                paragraphSpacing REAL NOT NULL DEFAULT 0.0,
                scroll INTEGER NOT NULL DEFAULT 0,
                publisherStyles INTEGER NOT NULL DEFAULT 0,
                justified INTEGER NOT NULL DEFAULT 1,
                columnCount TEXT NOT NULL DEFAULT 'AUTO',
                createdAt INTEGER NOT NULL DEFAULT 0
            )
        """.trimIndent())
    }
}

val MIGRATION_3_4 = object : Migration(3, 4) {
    override fun migrate(db: SupportSQLiteDatabase) {

        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN kind TEXT NOT NULL DEFAULT 'HIGHLIGHT'")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN media TEXT NOT NULL DEFAULT 'EPUB'")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN pdfPage INTEGER")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN pdfRectsJson TEXT")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN cbzPage INTEGER")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN audioPositionMs INTEGER")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN chapterId TEXT")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN tagsJson TEXT NOT NULL DEFAULT '[]'")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN attachmentUriString TEXT")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN attachmentKind TEXT")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN updatedAt INTEGER NOT NULL DEFAULT 0")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN deletedAt INTEGER")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN serverId TEXT")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN providerSource TEXT NOT NULL DEFAULT 'local'")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN syncDirty INTEGER NOT NULL DEFAULT 1")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN syncEtag TEXT")

        db.execSQL("UPDATE reader_annotations SET kind = 'BOOKMARK', style = 'NONE' WHERE style = 'BOOKMARK'")

        db.execSQL("UPDATE reader_annotations SET updatedAt = createdAt WHERE updatedAt = 0")

        db.execSQL("CREATE INDEX IF NOT EXISTS index_reader_annotations_bookId ON reader_annotations(bookId)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_reader_annotations_kind ON reader_annotations(kind)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_reader_annotations_updatedAt ON reader_annotations(updatedAt)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_reader_annotations_deletedAt ON reader_annotations(deletedAt)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_reader_annotations_serverId ON reader_annotations(serverId)")
    }
}

val MIGRATION_4_5 = object : Migration(4, 5) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS reader_annotations_new (
                id TEXT NOT NULL PRIMARY KEY,
                bookId TEXT NOT NULL,
                kind TEXT NOT NULL,
                media TEXT NOT NULL,
                style TEXT NOT NULL,
                colorHex TEXT NOT NULL,
                locatorJson TEXT,
                pdfPage INTEGER,
                pdfRectsJson TEXT,
                cbzPage INTEGER,
                audioPositionMs INTEGER,
                chapterId TEXT,
                selectedText TEXT NOT NULL,
                note TEXT NOT NULL,
                tagsJson TEXT NOT NULL,
                attachmentUriString TEXT,
                attachmentKind TEXT,
                createdAt INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL,
                deletedAt INTEGER,
                serverId TEXT,
                providerSource TEXT NOT NULL,
                syncDirty INTEGER NOT NULL,
                syncEtag TEXT
            )
        """.trimIndent())

        db.execSQL("""
            INSERT INTO reader_annotations_new (
                id, bookId, kind, media, style, colorHex, locatorJson, pdfPage, pdfRectsJson,
                cbzPage, audioPositionMs, chapterId, selectedText, note, tagsJson,
                attachmentUriString, attachmentKind, createdAt, updatedAt, deletedAt,
                serverId, providerSource, syncDirty, syncEtag
            )
            SELECT
                id, bookId, kind, media, style, colorHex, locatorJson, pdfPage, pdfRectsJson,
                cbzPage, audioPositionMs, chapterId, selectedText, note, tagsJson,
                attachmentUriString, attachmentKind, createdAt, updatedAt, deletedAt,
                serverId, providerSource, syncDirty, syncEtag
            FROM reader_annotations
        """.trimIndent())

        db.execSQL("DROP TABLE reader_annotations")
        db.execSQL("ALTER TABLE reader_annotations_new RENAME TO reader_annotations")

        db.execSQL("CREATE INDEX IF NOT EXISTS index_reader_annotations_bookId ON reader_annotations(bookId)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_reader_annotations_kind ON reader_annotations(kind)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_reader_annotations_updatedAt ON reader_annotations(updatedAt)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_reader_annotations_deletedAt ON reader_annotations(deletedAt)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_reader_annotations_serverId ON reader_annotations(serverId)")
    }
}

val MIGRATION_2_3 = object : Migration(2, 3) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS book_cache (
                cacheKey TEXT NOT NULL PRIMARY KEY,
                id TEXT NOT NULL,
                connectionId TEXT,
                source TEXT NOT NULL,
                mediaType TEXT NOT NULL,
                title TEXT NOT NULL,
                author TEXT,
                narrator TEXT,
                coverUrl TEXT,
                duration INTEGER NOT NULL DEFAULT 0,
                currentTime INTEGER NOT NULL DEFAULT 0,
                isFinished INTEGER NOT NULL DEFAULT 0,
                readProgress REAL NOT NULL DEFAULT 0,
                epubProgress REAL,
                epubLocator TEXT,
                lastReadTime INTEGER NOT NULL DEFAULT 0,
                addedOn INTEGER NOT NULL DEFAULT 0,
                libraryId TEXT,
                libraryName TEXT,
                seriesName TEXT,
                seriesNumber TEXT,
                publisher TEXT,
                publishedDate TEXT,
                description TEXT,
                language TEXT,
                pageCount INTEGER,
                isDownloaded INTEGER NOT NULL DEFAULT 0,
                hideFromContinue INTEGER NOT NULL DEFAULT 0,
                readAlongAvailable INTEGER NOT NULL DEFAULT 0,
                categoriesJson TEXT NOT NULL DEFAULT '[]',
                subtitle TEXT,
                isbn13 TEXT,
                personalRating REAL,
                goodreadsRating REAL,
                primaryFileType TEXT,
                inProgress INTEGER NOT NULL DEFAULT 0,
                cachedAt INTEGER NOT NULL DEFAULT 0
            )
        """.trimIndent())
        db.execSQL("CREATE INDEX IF NOT EXISTS index_book_cache_connectionId ON book_cache(connectionId)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_book_cache_source ON book_cache(source)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_book_cache_mediaType ON book_cache(mediaType)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_book_cache_lastReadTime ON book_cache(lastReadTime)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_book_cache_addedOn ON book_cache(addedOn)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_book_cache_isFinished ON book_cache(isFinished)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_book_cache_readProgress ON book_cache(readProgress)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_book_cache_inProgress ON book_cache(inProgress)")
    }
}

val MIGRATION_5_6 = object : Migration(5, 6) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS book_extras (
                cacheKey TEXT NOT NULL PRIMARY KEY,
                chaptersJson TEXT NOT NULL DEFAULT '[]',
                audioTracksJson TEXT NOT NULL DEFAULT '[]',
                updatedAt INTEGER NOT NULL DEFAULT 0
            )
        """.trimIndent())
    }
}

val MIGRATION_6_7 = object : Migration(6, 7) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS library_cache (
                id TEXT NOT NULL PRIMARY KEY,
                name TEXT NOT NULL,
                source TEXT NOT NULL,
                connectionId TEXT,
                bookCount INTEGER NOT NULL DEFAULT 0,
                cachedAt INTEGER NOT NULL DEFAULT 0
            )
        """.trimIndent())
    }
}

val MIGRATION_7_8 = object : Migration(7, 8) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS pending_progress_push (
                bookId TEXT NOT NULL PRIMARY KEY,
                mediaType TEXT NOT NULL,
                percentage REAL NOT NULL,
                isFinished INTEGER NOT NULL,
                createdAt INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 1,
                lastAttemptAt INTEGER NOT NULL DEFAULT 0,
                lastError TEXT
            )
        """.trimIndent())
    }
}

val MIGRATION_9_10 = object : Migration(9, 10) {
    override fun migrate(db: SupportSQLiteDatabase) {

        db.execSQL("ALTER TABLE book_cache ADD COLUMN narratorEnrichedAt INTEGER NOT NULL DEFAULT 0")
    }
}

val MIGRATION_10_11 = object : Migration(10, 11) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN cfi TEXT")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN cssSelector TEXT")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN textQuoteExact TEXT")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN textQuotePrefix TEXT")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN textQuoteSuffix TEXT")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN progression REAL")
        db.execSQL("ALTER TABLE reader_annotations ADD COLUMN totalProgression REAL")
    }
}

val MIGRATION_8_9 = object : Migration(8, 9) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS vocab_entries (
                id TEXT NOT NULL PRIMARY KEY,
                bookStableId TEXT NOT NULL,
                word TEXT NOT NULL,
                sentence TEXT NOT NULL,
                sentenceBefore TEXT NOT NULL,
                sentenceAfter TEXT NOT NULL,
                locator TEXT,
                position REAL NOT NULL,
                chapterTitle TEXT,
                definitionSnapshot TEXT,
                userNote TEXT,
                lookedUpAt INTEGER NOT NULL,
                tags TEXT NOT NULL,
                sourceLanguage TEXT,
                studyBox INTEGER NOT NULL,
                nextReviewAt INTEGER,
                lastReviewedAt INTEGER,
                reviewStreak INTEGER NOT NULL
            )
        """.trimIndent())
        db.execSQL("CREATE INDEX IF NOT EXISTS index_vocab_entries_bookStableId ON vocab_entries (bookStableId)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_vocab_entries_nextReviewAt ON vocab_entries (nextReviewAt)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_vocab_entries_lookedUpAt ON vocab_entries (lookedUpAt)")
    }
}

val MIGRATION_11_12 = object : Migration(11, 12) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS custom_fonts (
                id TEXT NOT NULL PRIMARY KEY,
                displayName TEXT NOT NULL,
                regularPath TEXT,
                boldPath TEXT,
                italicPath TEXT,
                boldItalicPath TEXT,
                addedAt INTEGER NOT NULL
            )
        """.trimIndent())
    }
}

val MIGRATION_12_13 = object : Migration(12, 13) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS linked_book_pairs (
                ebookKey TEXT NOT NULL PRIMARY KEY,
                audiobookKey TEXT NOT NULL,
                chapterOffset INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL
            )
        """.trimIndent())
        db.execSQL("CREATE INDEX IF NOT EXISTS index_linked_book_pairs_audiobookKey ON linked_book_pairs (audiobookKey)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_linked_book_pairs_updatedAt ON linked_book_pairs (updatedAt)")
    }
}

val MIGRATION_13_14 = object : Migration(13, 14) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS user_collections (
                id TEXT NOT NULL PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                iconName TEXT NOT NULL,
                colorHex TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL
            )
        """.trimIndent())
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS user_collection_books (
                collectionId TEXT NOT NULL,
                bookKey TEXT NOT NULL,
                addedAt INTEGER NOT NULL,
                PRIMARY KEY(collectionId, bookKey),
                FOREIGN KEY(collectionId) REFERENCES user_collections(id) ON DELETE CASCADE
            )
        """.trimIndent())
        db.execSQL("CREATE INDEX IF NOT EXISTS index_user_collections_name ON user_collections (name)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_user_collections_updatedAt ON user_collections (updatedAt)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_user_collection_books_bookKey ON user_collection_books (bookKey)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_user_collection_books_addedAt ON user_collection_books (addedAt)")
    }
}

val MIGRATION_14_15 = object : Migration(14, 15) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS book_metadata_overrides (
                bookKey TEXT NOT NULL PRIMARY KEY,
                title TEXT NOT NULL,
                subtitle TEXT,
                author TEXT,
                narrator TEXT,
                description TEXT,
                seriesName TEXT,
                seriesNumber TEXT,
                publisher TEXT,
                publishedDate TEXT,
                isbn13 TEXT,
                language TEXT,
                pageCount INTEGER,
                updatedAt INTEGER NOT NULL
            )
        """.trimIndent())
        db.execSQL("CREATE INDEX IF NOT EXISTS index_book_metadata_overrides_updatedAt ON book_metadata_overrides (updatedAt)")
    }
}

val MIGRATION_15_16 = object : Migration(15, 16) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS custom_smart_collections (
                id TEXT NOT NULL PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                mediaType TEXT,
                status TEXT NOT NULL,
                length TEXT NOT NULL,
                addedWithinDays INTEGER,
                query TEXT,
                createdAt INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL
            )
        """.trimIndent())
        db.execSQL("CREATE INDEX IF NOT EXISTS index_custom_smart_collections_updatedAt ON custom_smart_collections (updatedAt)")
    }
}

val MIGRATION_16_17 = object : Migration(16, 17) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS pending_progress_push_new (
                bookId TEXT NOT NULL,
                source TEXT NOT NULL,
                connectionKey TEXT NOT NULL,
                mediaType TEXT NOT NULL,
                percentage REAL NOT NULL,
                isFinished INTEGER NOT NULL,
                createdAt INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 1,
                lastAttemptAt INTEGER NOT NULL DEFAULT 0,
                lastError TEXT,
                PRIMARY KEY(source, connectionKey, bookId)
            )
        """.trimIndent())
        db.execSQL("""
            INSERT INTO pending_progress_push_new (
                bookId, source, connectionKey, mediaType, percentage, isFinished,
                createdAt, attempts, lastAttemptAt, lastError
            )
            SELECT
                bookId, 'GRIMMORY', '', mediaType, percentage, isFinished,
                createdAt, attempts, lastAttemptAt, lastError
            FROM pending_progress_push
        """.trimIndent())
        db.execSQL("DROP TABLE pending_progress_push")
        db.execSQL("ALTER TABLE pending_progress_push_new RENAME TO pending_progress_push")
    }
}

val MIGRATION_17_18 = object : Migration(17, 18) {
    override fun migrate(db: SupportSQLiteDatabase) {
        if (!db.hasColumn("book_cache", "hasAudio")) {
            db.execSQL("ALTER TABLE book_cache ADD COLUMN hasAudio INTEGER NOT NULL DEFAULT 0")
        }
        if (!db.hasColumn("book_cache", "hasEbook")) {
            db.execSQL("ALTER TABLE book_cache ADD COLUMN hasEbook INTEGER NOT NULL DEFAULT 0")
        }
        db.execSQL("UPDATE book_cache SET hasAudio = 1 WHERE mediaType = 'AUDIOBOOK' OR readAlongAvailable = 1")
        db.execSQL("UPDATE book_cache SET hasEbook = 1 WHERE mediaType = 'EBOOK' OR readAlongAvailable = 1")

        db.ensureTable(
            tableName = "linked_book_pairs",
            requiredColumns = setOf("ebookKey", "audiobookKey", "chapterOffset", "updatedAt"),
            createSql = """
                CREATE TABLE linked_book_pairs (
                    ebookKey TEXT NOT NULL PRIMARY KEY,
                    audiobookKey TEXT NOT NULL,
                    chapterOffset INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL
                )
            """.trimIndent(),
            indexSql = listOf(
                "CREATE INDEX IF NOT EXISTS index_linked_book_pairs_audiobookKey ON linked_book_pairs (audiobookKey)",
                "CREATE INDEX IF NOT EXISTS index_linked_book_pairs_updatedAt ON linked_book_pairs (updatedAt)",
            ),
        )

        if (
            !db.hasColumns("user_collections", setOf("id", "name", "description", "iconName", "colorHex", "createdAt", "updatedAt")) ||
            !db.hasColumns("user_collection_books", setOf("collectionId", "bookKey", "addedAt"))
        ) {
            db.execSQL("DROP TABLE IF EXISTS user_collection_books")
            db.execSQL("DROP TABLE IF EXISTS user_collections")
            db.execSQL("""
                CREATE TABLE user_collections (
                    id TEXT NOT NULL PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT,
                    iconName TEXT NOT NULL,
                    colorHex TEXT NOT NULL,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL
                )
            """.trimIndent())
            db.execSQL("""
                CREATE TABLE user_collection_books (
                    collectionId TEXT NOT NULL,
                    bookKey TEXT NOT NULL,
                    addedAt INTEGER NOT NULL,
                    PRIMARY KEY(collectionId, bookKey),
                    FOREIGN KEY(collectionId) REFERENCES user_collections(id) ON DELETE CASCADE
                )
            """.trimIndent())
            db.execSQL("CREATE INDEX IF NOT EXISTS index_user_collections_name ON user_collections (name)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_user_collections_updatedAt ON user_collections (updatedAt)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_user_collection_books_bookKey ON user_collection_books (bookKey)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_user_collection_books_addedAt ON user_collection_books (addedAt)")
        }

        db.ensureTable(
            tableName = "book_metadata_overrides",
            requiredColumns = setOf("bookKey", "title", "subtitle", "author", "narrator", "description", "seriesName", "seriesNumber", "publisher", "publishedDate", "isbn13", "language", "pageCount", "updatedAt"),
            createSql = """
                CREATE TABLE book_metadata_overrides (
                    bookKey TEXT NOT NULL PRIMARY KEY,
                    title TEXT NOT NULL,
                    subtitle TEXT,
                    author TEXT,
                    narrator TEXT,
                    description TEXT,
                    seriesName TEXT,
                    seriesNumber TEXT,
                    publisher TEXT,
                    publishedDate TEXT,
                    isbn13 TEXT,
                    language TEXT,
                    pageCount INTEGER,
                    updatedAt INTEGER NOT NULL
                )
            """.trimIndent(),
            indexSql = listOf("CREATE INDEX IF NOT EXISTS index_book_metadata_overrides_updatedAt ON book_metadata_overrides (updatedAt)"),
        )

        db.ensureTable(
            tableName = "custom_smart_collections",
            requiredColumns = setOf("id", "name", "description", "mediaType", "status", "length", "addedWithinDays", "query", "createdAt", "updatedAt"),
            createSql = """
                CREATE TABLE custom_smart_collections (
                    id TEXT NOT NULL PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT,
                    mediaType TEXT,
                    status TEXT NOT NULL,
                    length TEXT NOT NULL,
                    addedWithinDays INTEGER,
                    query TEXT,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL
                )
            """.trimIndent(),
            indexSql = listOf("CREATE INDEX IF NOT EXISTS index_custom_smart_collections_updatedAt ON custom_smart_collections (updatedAt)"),
        )
    }
}

val MIGRATION_18_19 = object : Migration(18, 19) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS matched_book_metadata (
                metadataKey TEXT NOT NULL PRIMARY KEY,
                bookId TEXT NOT NULL,
                source TEXT NOT NULL,
                mediaType TEXT NOT NULL,
                matchSource TEXT NOT NULL,
                externalId TEXT NOT NULL,
                title TEXT,
                subtitle TEXT,
                author TEXT,
                narrator TEXT,
                publisher TEXT,
                publishedDate TEXT,
                publishedYear INTEGER,
                isbn TEXT,
                coverUrl TEXT,
                durationSec INTEGER,
                pageCount INTEGER,
                seriesName TEXT,
                seriesNumber TEXT,
                description TEXT,
                categoriesJson TEXT NOT NULL DEFAULT '[]',
                language TEXT,
                rawJson TEXT,
                updatedAt INTEGER NOT NULL
            )
        """.trimIndent())
        db.execSQL("CREATE INDEX IF NOT EXISTS index_matched_book_metadata_bookId ON matched_book_metadata(bookId)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_matched_book_metadata_source ON matched_book_metadata(source)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_matched_book_metadata_updatedAt ON matched_book_metadata(updatedAt)")
    }
}

val MIGRATION_19_20 = object : Migration(19, 20) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS story_align_jobs (
                id TEXT NOT NULL PRIMARY KEY,
                ebookKey TEXT NOT NULL,
                audiobookKey TEXT NOT NULL,
                ebookTitle TEXT NOT NULL,
                audiobookTitle TEXT NOT NULL,
                author TEXT,
                connectionId TEXT,
                status TEXT NOT NULL,
                stage TEXT NOT NULL,
                stageProgress REAL NOT NULL,
                overallProgress REAL NOT NULL,
                settingsJson TEXT NOT NULL,
                sessionDir TEXT NOT NULL,
                outputPath TEXT,
                outputBookId TEXT,
                reportJson TEXT,
                errorMessage TEXT,
                errorStage TEXT,
                createdAt INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL
            )
        """.trimIndent())
        db.execSQL("CREATE INDEX IF NOT EXISTS index_story_align_jobs_status ON story_align_jobs(status)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_story_align_jobs_createdAt ON story_align_jobs(createdAt)")
    }
}

val MIGRATION_20_21 = object : Migration(20, 21) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE book_cache ADD COLUMN serverReadStatus TEXT")
        db.execSQL("UPDATE book_cache SET serverReadStatus = 'READ' WHERE isFinished = 1")
    }
}

val MIGRATION_21_22 = object : Migration(21, 22) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS playback_queue (
                bookKey TEXT NOT NULL PRIMARY KEY,
                position INTEGER NOT NULL,
                origin TEXT NOT NULL,
                groupKey TEXT,
                enqueuedAt INTEGER NOT NULL
            )
        """.trimIndent())
        db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_playback_queue_position ON playback_queue(position)")
    }
}

val MIGRATION_22_23 = object : Migration(22, 23) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS epub_bridge_checkpoints (
                bookKey TEXT NOT NULL PRIMARY KEY,
                publicationSha256 TEXT NOT NULL,
                providerFileId TEXT,
                schemaVersion INTEGER NOT NULL,
                revision INTEGER NOT NULL,
                writerEpoch INTEGER NOT NULL,
                observedAt INTEGER NOT NULL,
                checkpointJson TEXT NOT NULL
            )
        """.trimIndent())
    }
}

val MIGRATION_23_24 = object : Migration(23, 24) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL(
            "ALTER TABLE layout_presets ADD COLUMN paragraphIndent REAL NOT NULL DEFAULT 0.0",
        )
    }
}

private fun SupportSQLiteDatabase.hasColumn(tableName: String, columnName: String): Boolean {
    query("PRAGMA table_info(`$tableName`)").use { cursor ->
        val nameIndex = cursor.getColumnIndex("name")
        while (cursor.moveToNext()) {
            if (cursor.getString(nameIndex) == columnName) return true
        }
    }
    return false
}

private fun SupportSQLiteDatabase.hasColumns(tableName: String, columnNames: Set<String>): Boolean {
    val found = mutableSetOf<String>()
    query("PRAGMA table_info(`$tableName`)").use { cursor ->
        val nameIndex = cursor.getColumnIndex("name")
        while (cursor.moveToNext()) {
            found += cursor.getString(nameIndex)
        }
    }
    return found.containsAll(columnNames)
}

private fun SupportSQLiteDatabase.ensureTable(
    tableName: String,
    requiredColumns: Set<String>,
    createSql: String,
    indexSql: List<String> = emptyList(),
) {
    if (hasColumns(tableName, requiredColumns)) return
    execSQL("DROP TABLE IF EXISTS $tableName")
    execSQL(createSql)
    indexSql.forEach(::execSQL)
}

@Database(
    entities = [
        ReaderAnnotation::class,
        LayoutPreset::class,
        CachedBook::class,
        BookExtras::class,
        CachedLibrary::class,
        PendingProgressPush::class,
        com.enve.core.data.model.VocabEntry::class,
        com.enve.app.data.reader.CustomFont::class,
        LinkedBookPair::class,
        UserCollection::class,
        UserCollectionBook::class,
        BookMetadataOverride::class,
        CustomSmartCollection::class,
        MatchedBookMetadata::class,
        com.enve.app.storyalign.StoryAlignJobEntity::class,
        PlaybackQueueEntry::class,
        EpubBridgeCheckpointEntity::class,
    ],
    version  = 24,
    exportSchema = false,
)
abstract class ReaderDatabase : RoomDatabase() {
    abstract fun annotationDao(): ReaderAnnotationDao
    abstract fun layoutPresetDao(): LayoutPresetDao
    abstract fun bookCacheDao(): BookCacheDao
    abstract fun bookExtrasDao(): BookExtrasDao
    abstract fun libraryCacheDao(): LibraryCacheDao
    abstract fun pendingProgressPushDao(): PendingProgressPushDao
    abstract fun vocabEntryDao(): com.enve.core.data.model.VocabEntryDao
    abstract fun customFontDao(): com.enve.app.data.reader.CustomFontDao
    abstract fun linkedBookPairDao(): LinkedBookPairDao
    abstract fun userCollectionDao(): UserCollectionDao
    abstract fun bookMetadataOverrideDao(): BookMetadataOverrideDao
    abstract fun customSmartCollectionDao(): CustomSmartCollectionDao
    abstract fun matchedBookMetadataDao(): MatchedBookMetadataDao
    abstract fun storyAlignJobDao(): com.enve.app.storyalign.StoryAlignJobDao
    abstract fun playbackQueueDao(): PlaybackQueueDao
    abstract fun epubBridgeCheckpointDao(): EpubBridgeCheckpointDao

    companion object {
        @Volatile private var INSTANCE: ReaderDatabase? = null

        fun getInstance(context: Context): ReaderDatabase =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: Room.databaseBuilder(
                    context.applicationContext,
                    ReaderDatabase::class.java,
                    "reader.db",
                )
                    .addMigrations(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5, MIGRATION_5_6, MIGRATION_6_7, MIGRATION_7_8, MIGRATION_8_9, MIGRATION_9_10, MIGRATION_10_11, MIGRATION_11_12, MIGRATION_12_13, MIGRATION_13_14, MIGRATION_14_15, MIGRATION_15_16, MIGRATION_16_17, MIGRATION_17_18, MIGRATION_18_19, MIGRATION_19_20, MIGRATION_20_21, MIGRATION_21_22, MIGRATION_22_23, MIGRATION_23_24)

                    .fallbackToDestructiveMigrationOnDowngrade(dropAllTables = true)
                    .build()
                    .also { INSTANCE = it }
            }
    }
}
