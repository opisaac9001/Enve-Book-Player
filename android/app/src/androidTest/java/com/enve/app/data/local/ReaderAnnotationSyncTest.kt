package com.enve.app.data.local

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.repository.AnnotationRepository
import com.enve.app.data.repository.AnnotationScope
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.model.ReaderAnnotationDao
import com.enve.core.data.sync.AcceptedAnnotation
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.first
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReaderAnnotationSyncTest {

    private lateinit var db: ReaderDatabase
    private lateinit var dao: ReaderAnnotationDao
    private lateinit var repository: AnnotationRepository

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            ReaderDatabase::class.java,
        ).allowMainThreadQueries().build()
        dao = db.annotationDao()
        repository = AnnotationRepository(db)
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun fetchKeepsDirtyLocalEditAndCapturedEtag() = runBlocking {
        val local = annotation("local-1", serverId = "s-1", note = "mine", etag = "e-1", dirty = true, updatedAt = 100)
        dao.upsert(local)

        repository.applyRemote(SCOPE, listOf(remote("s-1", note = "theirs", etag = "e-2", updatedAt = 900)))

        assertEquals(local, dao.getById("local-1"))
        assertNull(dao.getById("s-1"))
    }

    @Test
    fun authoritativeFetchKeepsDirtyTombstoneAndUnsyncedRows() = runBlocking {
        val tombstone = annotation("local-1", serverId = "s-1", etag = "e-1", dirty = true, updatedAt = 200, deletedAt = 200)
        val unsynced = annotation("local-2", serverId = null, dirty = true)
        val dirtyMissing = annotation("local-3", serverId = "s-3", dirty = true)
        val cleanMissing = annotation("local-4", serverId = "s-4", dirty = false)
        listOf(tombstone, unsynced, dirtyMissing, cleanMissing).forEach { dao.upsert(it) }

        repository.applyAuthoritativeRemote(SCOPE, PROVIDER, listOf(remote("s-1", note = "theirs", etag = "e-2", updatedAt = 900)))

        assertEquals(tombstone, dao.getById("local-1"))
        assertEquals(unsynced, dao.getById("local-2"))
        assertEquals(dirtyMissing, dao.getById("local-3"))
        assertNull(dao.getById("local-4"))
        assertNull(dao.getById("s-1"))
    }

    @Test
    fun fetchUpdatesCleanRowInPlace() = runBlocking {
        dao.upsert(annotation("local-1", serverId = "s-1", note = "old", etag = "e-1", dirty = false))

        repository.applyRemote(SCOPE, listOf(remote("s-1", note = "new", etag = "e-2", updatedAt = 900)))

        val row = dao.getById("local-1")!!
        assertEquals("new", row.note)
        assertEquals("e-2", row.syncEtag)
        assertEquals(false, row.syncDirty)
        assertNull(dao.getById("s-1"))
    }

    @Test
    fun staleRemoteDoesNotResurrectCleanTombstone() = runBlocking {
        val tombstone = annotation("local-1", serverId = "s-1", dirty = false, updatedAt = 500, deletedAt = 500)
        dao.upsert(tombstone)

        repository.applyRemote(SCOPE, listOf(remote("s-1", note = "stale", updatedAt = 400)))

        assertEquals(tombstone, dao.getById("local-1"))
    }

    @Test
    fun remoteMatchingIsScopedToBook() = runBlocking {
        val otherBook = annotation("local-a", bookId = "book-a", serverId = "s-1", note = "a", dirty = false)
        dao.upsert(otherBook)

        repository.applyRemote(SCOPE, listOf(remote("s-1", bookId = BOOK, note = "b", updatedAt = 900)))

        assertEquals(otherBook, dao.getById("local-a"))
        val inserted = dao.getByBook(BOOK, null).single()
        assertEquals("s-1", inserted.serverId)
        assertEquals("b", inserted.note)
    }

    @Test
    fun remoteIdCollidingWithAnotherBookGetsItsOwnRow() = runBlocking {
        val otherBook = annotation("s-1", bookId = "book-a", serverId = null, note = "a", dirty = true)
        dao.upsert(otherBook)

        repository.applyRemote(SCOPE, listOf(remote("s-1", bookId = BOOK, note = "b", updatedAt = 900)))

        assertEquals(otherBook, dao.getById("s-1"))
        val inserted = dao.getByBook(BOOK, null).single()
        assertNotEquals("s-1", inserted.id)
        assertEquals("s-1", inserted.serverId)
    }

    @Test
    fun acknowledgementCleansUnchangedSnapshot() = runBlocking {
        val sent = annotation("local-1", serverId = null, dirty = true)
        dao.upsert(sent)

        repository.acknowledgePushed(listOf(sent), listOf(AcceptedAnnotation("local-1", serverId = "s-1", etag = "e-1")))

        val row = dao.getById("local-1")!!
        assertEquals(false, row.syncDirty)
        assertEquals("s-1", row.serverId)
        assertEquals("e-1", row.syncEtag)
    }

    @Test
    fun acknowledgementKeepsNewerEditDirtyAndAdoptsCreatedIdentity() = runBlocking {
        val sent = annotation("local-1", serverId = null, note = "first", dirty = true, updatedAt = 100)
        dao.upsert(sent)
        repository.update(sent, note = "second")

        repository.acknowledgePushed(listOf(sent), listOf(AcceptedAnnotation("local-1", serverId = "s-1", etag = "e-1")))

        val row = dao.getById("local-1")!!
        assertTrue(row.syncDirty)
        assertEquals("second", row.note)
        assertEquals("s-1", row.serverId)
        assertEquals("e-1", row.syncEtag)
    }

    @Test
    fun acknowledgementKeepsTombstoneCreatedWhileInFlight() = runBlocking {
        val sent = annotation("local-1", serverId = "s-1", etag = "e-1", dirty = true, updatedAt = 100)
        dao.upsert(sent)
        repository.delete("local-1")

        repository.acknowledgePushed(listOf(sent), listOf(AcceptedAnnotation("local-1", serverId = "s-1", etag = "e-2")))

        val row = dao.getById("local-1")!!
        assertTrue(row.syncDirty)
        assertNotNull(row.deletedAt)
        assertEquals("e-2", row.syncEtag)
    }

    @Test
    fun acknowledgementIgnoresIdsThatWereNotSent() = runBlocking {
        val sent = annotation("local-1", dirty = true)
        val unsent = annotation("local-2", dirty = true)
        dao.upsert(sent)
        dao.upsert(unsent)

        repository.acknowledgePushed(listOf(sent), listOf(AcceptedAnnotation("local-2", serverId = "s-2", etag = "e-2")))

        assertEquals(sent, dao.getById("local-1"))
        assertEquals(unsent, dao.getById("local-2"))
    }

    @Test
    fun editFromStaleCopyKeepsAcknowledgedIdentity() = runBlocking {
        val stale = annotation("local-1", serverId = null, note = "first", dirty = true, updatedAt = 100)
        dao.upsert(stale)
        repository.acknowledgePushed(listOf(stale), listOf(AcceptedAnnotation("local-1", serverId = "s-1", etag = "e-1")))

        repository.update(stale, note = "second")

        val row = dao.getById("local-1")!!
        assertTrue(row.syncDirty)
        assertEquals("second", row.note)
        assertEquals("s-1", row.serverId)
        assertEquals("e-1", row.syncEtag)
    }

    @Test
    fun sameBookIdOnTwoConnectionsKeepsSeparateListsAndPurges() = runBlocking {
        val first = annotation("grimmory-annotation-5", serverId = "s-5", note = "a", dirty = false, connectionId = "a")
        val firstDirty = annotation("a-dirty", dirty = true, connectionId = "a")
        dao.upsert(first)
        dao.upsert(firstDirty)

        repository.applyAuthoritativeRemote(SCOPE_B, PROVIDER, listOf(remote("s-5", note = "b", updatedAt = 900).copy(id = "grimmory-annotation-5")))

        assertEquals(first, dao.getById("grimmory-annotation-5"))
        val secondRow = dao.getByBook(BOOK, "b").single()
        assertNotEquals("grimmory-annotation-5", secondRow.id)
        assertEquals("b", secondRow.note)
        assertEquals("b", secondRow.connectionId)
        assertEquals(setOf("grimmory-annotation-5", "a-dirty"), dao.getByBook(BOOK, "a").map { it.id }.toSet())
        assertTrue(repository.dirtyFor(SCOPE_B).isEmpty())
        assertEquals(listOf("a-dirty"), repository.dirtyFor(AnnotationScope(BOOK, "a")).map { it.id })

        repository.applyAuthoritativeRemote(SCOPE_B, PROVIDER, emptyList())

        assertEquals(first, dao.getById("grimmory-annotation-5"))
        assertTrue(dao.getByBook(BOOK, "b").isEmpty())
    }

    @Test
    fun unresolvedLegacyRowsRemainInJournalWithoutEnteringAnyConnectionsBook() = runBlocking {
        val legacy = annotation("legacy", dirty = true).copy(connectionUnresolved = true)
        val legacyClean = annotation("legacy-clean", serverId = "s-9", dirty = false).copy(connectionUnresolved = true)
        dao.upsert(legacy)
        dao.upsert(legacyClean)
        val notified = mutableListOf<AnnotationScope>()
        repository.setChangeListener { notified += it }

        repository.update(legacy, note = "edited offline")
        repository.applyAuthoritativeRemote(SCOPE_B, PROVIDER, emptyList())

        assertTrue(dao.getByBook(BOOK, "b").isEmpty())
        assertTrue(dao.getByBook(BOOK, "a").isEmpty())
        assertEquals(setOf("legacy", "legacy-clean"), dao.flowAll().first().map { it.id }.toSet())
        assertTrue(repository.dirtyFor(SCOPE_B).isEmpty())
        assertTrue(repository.dirtyFor(SCOPE).isEmpty())
        assertEquals(listOf(SCOPE_B), notified)
        assertTrue(dao.getById("legacy")!!.connectionUnresolved)
        assertEquals("edited offline", dao.getById("legacy")!!.note)
    }

    @Test
    fun matchingRemoteIdCannotTakeOverAnUnresolvedLegacyRow() = runBlocking {
        dao.upsert(annotation("legacy-clean", serverId = "s-9", note = "old", dirty = false).copy(connectionUnresolved = true))
        dao.upsert(annotation("legacy-dirty", serverId = "s-8", note = "mine", dirty = true).copy(connectionUnresolved = true))

        repository.applyRemote(SCOPE_B, listOf(remote("s-9", note = "server", updatedAt = 900), remote("s-8", note = "server", updatedAt = 900)))

        val adopted = dao.getById("legacy-clean")!!
        assertNull(adopted.connectionId)
        assertEquals("old", adopted.note)
        assertTrue(adopted.connectionUnresolved)
        assertEquals(1, dao.getByBook(BOOK, "b").count { it.serverId == "s-9" })
        val kept = dao.getById("legacy-dirty")!!
        assertTrue(kept.connectionUnresolved)
        assertEquals("mine", kept.note)
        assertEquals(1, dao.getByBook(BOOK, "b").count { it.serverId == "s-8" && !it.connectionUnresolved })
    }

    private fun annotation(
        id: String,
        bookId: String = BOOK,
        serverId: String? = null,
        note: String = "",
        etag: String? = null,
        dirty: Boolean,
        updatedAt: Long = 100,
        deletedAt: Long? = null,
        connectionId: String? = null,
    ) = ReaderAnnotation(
        id = id,
        bookId = bookId,
        note = note,
        createdAt = 50,
        updatedAt = updatedAt,
        deletedAt = deletedAt,
        serverId = serverId,
        providerSource = PROVIDER,
        syncDirty = dirty,
        syncEtag = etag,
        connectionId = connectionId,
    )

    private fun remote(
        serverId: String,
        bookId: String = BOOK,
        note: String = "",
        etag: String? = null,
        updatedAt: Long,
    ) = annotation(
        id = serverId,
        bookId = bookId,
        serverId = serverId,
        note = note,
        etag = etag,
        dirty = false,
        updatedAt = updatedAt,
    )

    private companion object {
        const val BOOK = "book-b"
        const val PROVIDER = "silo"
        val SCOPE = AnnotationScope(BOOK, null)
        val SCOPE_B = AnnotationScope(BOOK, "b")
    }
}
