package com.enve.app.data.local

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProfileStorageLocationsTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private lateinit var root: File
    private val databases = mutableListOf<ReaderDatabase>()

    @Before
    fun setUp() {
        root = File(context.cacheDir, "profile-storage-test-${UUID.randomUUID()}")
        check(root.mkdirs())
    }

    @After
    fun tearDown() {
        databases.forEach { it.close() }
        root.deleteRecursively()
    }

    @Test
    fun ownerKeepsLegacyPathsAndChildrenHaveSeparateRoots() {
        val owner = locations(DEFAULT_ADULT_PROFILE_ID)
        val child = locations("child-one")
        val otherChild = locations("child-two")

        assertEquals(File(root, "databases/reader.db"), owner.readerDatabaseFile)
        assertEquals(File(root, "files"), owner.filesDirectory)
        assertEquals(File(root, "cache"), owner.cacheDirectory)
        assertEquals(File(root, "files/datastore/enve_prefs.preferences_pb"), owner.envePreferencesFile)
        assertEquals(File(root, "files/datastore/hearth_prefs.preferences_pb"), owner.hearthPreferencesFile)
        assertEquals(File(root, "databases/profiles/child-one/reader.db"), child.readerDatabaseFile)
        assertEquals(File(root, "files/profiles/child-one"), child.filesDirectory)
        assertEquals(File(root, "cache/profiles/child-one"), child.cacheDirectory)
        assertNotEquals(child.readerDatabaseFile, otherChild.readerDatabaseFile)
        assertNotEquals(owner.envePreferencesFile, child.envePreferencesFile)
        assertFalse(child.filesDirectory.exists())
        assertFalse(child.readerDatabaseFile.exists())
    }

    @Test
    fun identicalBookIdsRemainIndependentAcrossOpenAndReopenedProfiles() = runBlocking {
        val owner = open(locations(DEFAULT_ADULT_PROFILE_ID))
        val child = open(locations("child-one"))
        owner.bookCacheDao().upsert(listOf(book("Owner book", 0.75f)))
        child.bookCacheDao().upsert(listOf(book("Child book", 0.25f)))

        assertEquals("Owner book", owner.bookCacheDao().getById("42")?.title)
        assertEquals("Child book", child.bookCacheDao().getById("42")?.title)
        assertEquals(0.75f, owner.bookCacheDao().getById("42")?.readProgress)
        assertEquals(0.25f, child.bookCacheDao().getById("42")?.readProgress)

        child.close()
        databases.remove(child)
        val reopened = open(locations("child-one"))
        assertEquals("Child book", reopened.bookCacheDao().getById("42")?.title)
        owner.bookCacheDao().upsert(listOf(book("Owner updated", 0.9f)))
        assertEquals("Child book", reopened.bookCacheDao().getById("42")?.title)
    }

    @Test
    fun failedChildDowngradePreservesChildDataAndLeavesOwnerUsable() = runBlocking {
        val owner = open(locations(DEFAULT_ADULT_PROFILE_ID))
        owner.bookCacheDao().upsert(listOf(book("Owner book", 0.75f)))
        val child = locations("child-newer")
        check(child.readerDatabaseFile.parentFile!!.mkdirs())
        SQLiteDatabase.openOrCreateDatabase(child.readerDatabaseFile, null).use { database ->
            database.execSQL("CREATE TABLE preserved_data (value TEXT NOT NULL)")
            database.execSQL("INSERT INTO preserved_data VALUES ('child data')")
            database.version = 29
        }

        try {
            ReaderDatabase.open(context, child).also { it.close() }
            fail("Opening a newer profile database must fail without destructive fallback")
        } catch (_: IllegalStateException) {
        }

        SQLiteDatabase.openDatabase(child.readerDatabaseFile.path, null, SQLiteDatabase.OPEN_READONLY).use { database ->
            database.rawQuery("SELECT value FROM preserved_data", null).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("child data", cursor.getString(0))
            }
            assertEquals(29, database.version)
        }
        owner.bookCacheDao().upsert(listOf(book("Owner still usable", 0.8f)))
        assertEquals("Owner still usable", owner.bookCacheDao().getById("42")?.title)
    }

    @Test
    fun rejectsProfileIdsThatEscapeTheirStorageRoot() {
        for (id in listOf("", "../adult-default", "/adult-default", "child/other", "..")) {
            try {
                locations(id)
                fail("Invalid profile identifier was accepted")
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    private fun locations(profileId: String) = ProfileStorageLocations.forProfile(
        profileId = profileId,
        filesDirectory = File(root, "files"),
        cacheDirectory = File(root, "cache"),
        databaseDirectory = File(root, "databases"),
    )

    private fun open(locations: ProfileStorageLocations): ReaderDatabase =
        ReaderDatabase.open(context, locations).also { databases += it }

    private fun book(title: String, progress: Float) = CachedBook(
        cacheKey = "same-connection:42",
        id = "42",
        connectionId = "same-connection",
        source = "GRIMMORY",
        mediaType = "EBOOK",
        title = title,
        author = null,
        narrator = null,
        coverUrl = null,
        duration = 0L,
        currentTime = 0L,
        isFinished = false,
        readProgress = progress,
        epubProgress = null,
        epubLocator = null,
        lastReadTime = 0L,
        addedOn = 0L,
        libraryId = null,
        libraryName = null,
        seriesName = null,
        seriesNumber = null,
        publisher = null,
        publishedDate = null,
        description = null,
        language = null,
        pageCount = null,
        isDownloaded = false,
        hideFromContinue = false,
        readAlongAvailable = false,
        categoriesJson = "[]",
        subtitle = null,
        isbn13 = null,
        personalRating = null,
        goodreadsRating = null,
        primaryFileType = null,
        inProgress = true,
        cachedAt = 0L,
    )
}
