package com.enve.app.data.local

import android.content.Context
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReaderDatabaseMigrationTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private lateinit var helper: SupportSQLiteOpenHelper

    @Before
    fun setUp() {
        context.deleteDatabase(DB_NAME)
        helper = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(DB_NAME)
                .callback(object : SupportSQLiteOpenHelper.Callback(24) {
                    override fun onCreate(db: SupportSQLiteDatabase) {
                        db.execSQL(CREATE_BOOK_CACHE_V24)
                    }

                    override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
                })
                .build()
        )
    }

    @After
    fun tearDown() {
        helper.close()
        context.deleteDatabase(DB_NAME)
    }

    @Test
    fun migration_24_to_25_backfills_opds_rows_without_dropping_anything() {
        val db = helper.writableDatabase
        insert(db, "conn-1:https://opds.example.com/a.epub", "https://opds.example.com/a.epub", "OPDS", 0.5f)
        insert(db, "conn-1:urn:uuid:stable", "urn:uuid:stable", "OPDS", 0.25f)
        insert(db, "conn-2:https://komga.example.com/b", "https://komga.example.com/b", "KOMGA", 0.75f)

        MIGRATION_24_25.migrate(db)

        assertTrue(columnNames(db, "book_cache").containsAll(setOf("opdsAcquisitionUrl", "opdsProgressionUrl")))
        assertEquals(3, count(db))
        assertEquals(
            "https://opds.example.com/a.epub",
            acquisitionUrl(db, "conn-1:https://opds.example.com/a.epub"),
        )
        assertNull(acquisitionUrl(db, "conn-1:urn:uuid:stable"))
        assertNull(acquisitionUrl(db, "conn-2:https://komga.example.com/b"))
        assertEquals(0.5f, readProgress(db, "conn-1:https://opds.example.com/a.epub"), 0.0001f)
        assertEquals(0.75f, readProgress(db, "conn-2:https://komga.example.com/b"), 0.0001f)
    }

    @Test
    fun the_new_columns_are_nullable_text() {
        val db = helper.writableDatabase
        MIGRATION_24_25.migrate(db)

        assertNullableText(db, "opdsAcquisitionUrl")
        assertNullableText(db, "opdsProgressionUrl")
    }

    @Test
    fun rerunning_the_migration_leaves_the_columns_and_their_values_alone() {
        val db = helper.writableDatabase
        insert(db, "conn-1:https://opds.example.com/a.epub", "https://opds.example.com/a.epub", "OPDS", 0.5f)

        MIGRATION_24_25.migrate(db)
        db.execSQL(
            "UPDATE book_cache SET opdsProgressionUrl = ? WHERE cacheKey = ?",
            arrayOf("https://opds.example.com/a/progression", "conn-1:https://opds.example.com/a.epub"),
        )
        MIGRATION_24_25.migrate(db)

        assertEquals(1, count(db))
        assertEquals(
            "https://opds.example.com/a/progression",
            textColumn(db, "opdsProgressionUrl", "conn-1:https://opds.example.com/a.epub"),
        )
    }

    @Test
    fun the_migration_creates_the_progression_state_table_and_keeps_its_rows_on_a_rerun() {
        val db = helper.writableDatabase

        MIGRATION_24_25.migrate(db)
        assertEquals(
            setOf("bookKey", "unhandledReferences", "updatedAt"),
            columnNames(db, "opds_progression_state"),
        )

        db.execSQL(
            "INSERT INTO opds_progression_state (bookKey, unhandledReferences, updatedAt) VALUES (?, ?, ?)",
            arrayOf<Any>("conn-1:https://opds.example.com/a.epub", """["#xywh=160,120,320,240"]""", 1L),
        )
        MIGRATION_24_25.migrate(db)

        db.query("SELECT unhandledReferences FROM opds_progression_state").use {
            assertEquals(1, it.count)
            it.moveToFirst()
            assertEquals("""["#xywh=160,120,320,240"]""", it.getString(0))
        }
    }

    @Test
    fun migration_25_to_26_adds_the_acquisition_table_without_touching_book_rows() {
        val db = helper.writableDatabase
        insert(db, "conn-1:urn:uuid:stable", "urn:uuid:stable", "OPDS", 0.25f)
        MIGRATION_24_25.migrate(db)

        MIGRATION_25_26.migrate(db)

        assertTrue(
            columnNames(db, "opds_acquisition").containsAll(
                setOf("rowKey", "bookKey", "position", "kind", "href", "format", "drm", "priceValue"),
            ),
        )
        assertEquals(1, count(db))
        assertEquals(0.25f, readProgress(db, "conn-1:urn:uuid:stable"), 0.0001f)
    }

    @Test
    fun rerunning_the_acquisition_migration_keeps_its_rows() {
        val db = helper.writableDatabase
        MIGRATION_24_25.migrate(db)
        MIGRATION_25_26.migrate(db)

        db.execSQL(
            """
            INSERT INTO opds_acquisition (
                rowKey, bookKey, position, kind, href, mediaType, format, drm,
                requiresIndirectFetch, indirectJson, updatedAt
            ) VALUES (?, ?, 0, 'BORROW', ?, 'application/epub+zip', 'EPUB', 'LCP', 0, '[]', 1)
            """.trimIndent(),
            arrayOf("conn-1:urn:uuid:stable|0", "conn-1:urn:uuid:stable", "https://opds.example.com/borrow"),
        )
        MIGRATION_25_26.migrate(db)

        db.query("SELECT kind, drm FROM opds_acquisition").use {
            assertEquals(1, it.count)
            it.moveToFirst()
            assertEquals("BORROW", it.getString(0))
            assertEquals("LCP", it.getString(1))
        }
    }

    @Test
    fun migration_25_to_26_adds_the_progression_state_columns_without_dropping_rows() {
        val db = helper.writableDatabase
        MIGRATION_24_25.migrate(db)
        db.execSQL(
            "INSERT INTO opds_progression_state (bookKey, unhandledReferences, updatedAt) VALUES (?, ?, ?)",
            arrayOf<Any>("conn-1:urn:uuid:stable", """["#xywh=1,2,3,4"]""", 1L),
        )

        MIGRATION_25_26.migrate(db)

        assertTrue(
            columnNames(db, "opds_progression_state").containsAll(setOf("authenticateUrl", "additionalMembers")),
        )
        db.query("SELECT unhandledReferences FROM opds_progression_state").use {
            assertEquals(1, it.count)
            it.moveToFirst()
            assertEquals("""["#xywh=1,2,3,4"]""", it.getString(0))
        }
    }

    @Test
    fun a_half_built_acquisition_table_gains_its_columns_instead_of_being_dropped() {
        val db = helper.writableDatabase
        MIGRATION_24_25.migrate(db)
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS opds_acquisition (
                rowKey TEXT NOT NULL PRIMARY KEY,
                bookKey TEXT NOT NULL,
                position INTEGER NOT NULL,
                kind TEXT NOT NULL,
                href TEXT NOT NULL,
                mediaType TEXT NOT NULL,
                format TEXT NOT NULL,
                drm TEXT NOT NULL,
                requiresIndirectFetch INTEGER NOT NULL,
                indirectJson TEXT NOT NULL,
                updatedAt INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL(
            """
            INSERT INTO opds_acquisition (
                rowKey, bookKey, position, kind, href, mediaType, format, drm,
                requiresIndirectFetch, indirectJson, updatedAt
            ) VALUES (?, ?, 0, 'OPEN_ACCESS', ?, 'application/epub+zip', 'EPUB', 'NONE', 0, '[]', 1)
            """.trimIndent(),
            arrayOf("conn-1:urn:uuid:stable|0", "conn-1:urn:uuid:stable", "https://opds.example.com/a.epub"),
        )

        MIGRATION_25_26.migrate(db)

        assertTrue(
            columnNames(db, "opds_acquisition").containsAll(
                setOf("priceCurrency", "priceValue", "availabilityState", "copiesTotal", "holdsPosition", "title"),
            ),
        )
        db.query("SELECT href, priceValue FROM opds_acquisition").use {
            assertEquals(1, it.count)
            it.moveToFirst()
            assertEquals("https://opds.example.com/a.epub", it.getString(0))
            assertTrue(it.isNull(1))
        }
        assertTrue(indexNames(db, "opds_acquisition").contains("index_opds_acquisition_bookKey"))
    }

    @Test
    fun the_acquisition_index_is_created_even_when_the_table_already_exists() {
        val db = helper.writableDatabase
        MIGRATION_24_25.migrate(db)
        MIGRATION_25_26.migrate(db)
        db.execSQL("DROP INDEX IF EXISTS index_opds_acquisition_bookKey")

        MIGRATION_25_26.migrate(db)

        assertTrue(indexNames(db, "opds_acquisition").contains("index_opds_acquisition_bookKey"))
    }

    private fun indexNames(db: SupportSQLiteDatabase, table: String): Set<String> =
        db.query("PRAGMA index_list(`$table`)").use { cursor ->
            val nameIndex = cursor.getColumnIndexOrThrow("name")
            buildSet { while (cursor.moveToNext()) add(cursor.getString(nameIndex)) }
        }

    private fun assertNullableText(db: SupportSQLiteDatabase, column: String) {
        db.query("PRAGMA table_info(`book_cache`)").use { cursor ->
            val nameIndex = cursor.getColumnIndexOrThrow("name")
            val typeIndex = cursor.getColumnIndexOrThrow("type")
            val notNullIndex = cursor.getColumnIndexOrThrow("notnull")
            while (cursor.moveToNext()) {
                if (cursor.getString(nameIndex) != column) continue
                assertEquals("TEXT", cursor.getString(typeIndex))
                assertEquals(0, cursor.getInt(notNullIndex))
                return
            }
        }
        throw AssertionError("$column column was not added")
    }

    private fun insert(db: SupportSQLiteDatabase, cacheKey: String, id: String, source: String, progress: Float) {
        db.execSQL(
            "INSERT INTO book_cache (cacheKey, id, connectionId, source, title, readProgress) VALUES (?, ?, ?, ?, ?, ?)",
            arrayOf<Any>(cacheKey, id, cacheKey.substringBefore(':'), source, "Title $id", progress),
        )
    }

    private fun columnNames(db: SupportSQLiteDatabase, table: String): Set<String> =
        db.query("PRAGMA table_info(`$table`)").use { cursor ->
            val nameIndex = cursor.getColumnIndexOrThrow("name")
            buildSet { while (cursor.moveToNext()) add(cursor.getString(nameIndex)) }
        }

    private fun count(db: SupportSQLiteDatabase): Int =
        db.query("SELECT COUNT(*) FROM book_cache").use { it.moveToFirst(); it.getInt(0) }

    private fun acquisitionUrl(db: SupportSQLiteDatabase, cacheKey: String): String? =
        textColumn(db, "opdsAcquisitionUrl", cacheKey)

    private fun textColumn(db: SupportSQLiteDatabase, column: String, cacheKey: String): String? =
        db.query("SELECT $column FROM book_cache WHERE cacheKey = ?", arrayOf(cacheKey)).use {
            it.moveToFirst()
            if (it.isNull(0)) null else it.getString(0)
        }

    private fun readProgress(db: SupportSQLiteDatabase, cacheKey: String): Float =
        db.query("SELECT readProgress FROM book_cache WHERE cacheKey = ?", arrayOf(cacheKey)).use {
            it.moveToFirst()
            it.getFloat(0)
        }

    private companion object {
        const val DB_NAME = "migration-24-25-test.db"
        val CREATE_BOOK_CACHE_V24 = """
            CREATE TABLE IF NOT EXISTS book_cache (
                cacheKey TEXT NOT NULL PRIMARY KEY,
                id TEXT NOT NULL,
                connectionId TEXT,
                source TEXT NOT NULL,
                title TEXT NOT NULL,
                readProgress REAL NOT NULL
            )
        """.trimIndent()
    }
}
