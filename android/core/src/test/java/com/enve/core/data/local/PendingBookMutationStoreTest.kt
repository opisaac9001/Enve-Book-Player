package com.enve.core.data.local

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class PendingBookMutationStoreTest {
    private val directory: File = Files.createTempDirectory("pending-book-mutations").toFile()
    private val file = File(directory, "sync/pending_book_mutations.json")

    @After
    fun tearDown() {
        directory.deleteRecursively()
    }

    private fun identity(
        kind: PendingBookMutationKind = PendingBookMutationKind.RATING,
        connection: String = "connection-a",
        account: String = "http://localhost|reader",
        bookId: String = "101",
    ) = PendingBookMutationIdentity(BookSource.BOOKORBIT.name, connection, account, bookId, kind)

    @Test
    fun latestEditReplacesEarlierEditForSameIdentity(): Unit = runBlocking {
        val store = PendingBookMutationStore(file)
        val first = store.enqueue(identity(), "3", now = 10L)
        val second = store.enqueue(identity(), "5", now = 20L)

        assertNotNull(first)
        assertNotNull(second)
        assertEquals(1, store.mutations.value.size)
        assertEquals("5", store.mutations.value.single().value)
        assertTrue(second!!.revision > first!!.revision)
    }

    @Test
    fun identitySeparatesKindConnectionAccountAndBook(): Unit = runBlocking {
        val store = PendingBookMutationStore(file)
        store.enqueue(identity(), "4", now = 1L)
        store.enqueue(identity(kind = PendingBookMutationKind.READ_STATUS), "READ", now = 2L)
        store.enqueue(identity(connection = "connection-b"), "2", now = 3L)
        store.enqueue(identity(account = "http://localhost|other"), "1", now = 4L)
        store.enqueue(identity(bookId = "102"), "5", now = 5L)

        assertEquals(5, store.mutations.value.size)
        assertEquals("4", store.find(identity())?.value)
        assertEquals("READ", store.find(identity(kind = PendingBookMutationKind.READ_STATUS))?.value)
    }

    @Test
    fun acknowledgingStaleRevisionKeepsNewerEdit(): Unit = runBlocking {
        val store = PendingBookMutationStore(file)
        val sent = store.enqueue(identity(), "3", now = 10L)!!
        val newer = store.enqueue(identity(), "4", now = 20L)!!

        assertFalse(store.acknowledge(identity(), sent.revision))
        assertEquals(newer, store.find(identity()))
        assertTrue(store.acknowledge(identity(), newer.revision))
        assertNull(store.find(identity()))
    }

    @Test
    fun failureForStaleRevisionDoesNotMarkNewerEdit(): Unit = runBlocking {
        val store = PendingBookMutationStore(file)
        val sent = store.enqueue(identity(), "3", now = 10L)!!
        store.enqueue(identity(), "4", now = 20L)

        assertFalse(store.recordFailure(identity(), sent.revision, PendingBookMutationFailure.AUTH, now = 30L))
        val current = store.find(identity())!!
        assertNull(current.failure)
        assertEquals(0, current.attempts)
    }

    @Test
    fun editsAndFailureStateSurviveRelaunch(): Unit = runBlocking {
        val first = PendingBookMutationStore(file)
        val rating = first.enqueue(identity(), "4", now = 10L)!!
        first.enqueue(identity(kind = PendingBookMutationKind.READ_STATUS), "ON_HOLD", now = 11L)
        first.recordFailure(identity(), rating.revision, PendingBookMutationFailure.TRANSIENT, now = 40L)

        val relaunched = PendingBookMutationStore(file)
        val restored = relaunched.find(identity())!!
        assertEquals("4", restored.value)
        assertEquals(1, restored.attempts)
        assertEquals(40L, restored.lastAttemptAt)
        assertEquals(PendingBookMutationFailure.TRANSIENT, restored.failure)
        assertEquals("ON_HOLD", relaunched.find(identity(kind = PendingBookMutationKind.READ_STATUS))?.value)
    }

    @Test
    fun revisionsKeepIncreasingAfterRelaunch(): Unit = runBlocking {
        val first = PendingBookMutationStore(file)
        val before = first.enqueue(identity(), "2", now = 1L)!!
        first.acknowledge(identity(), before.revision)

        val after = PendingBookMutationStore(file).enqueue(identity(), "3", now = 2L)!!
        assertTrue(after.revision > before.revision)
    }

    @Test
    fun newEditClearsEarlierFailureState(): Unit = runBlocking {
        val store = PendingBookMutationStore(file)
        val failed = store.enqueue(identity(), "2", now = 1L)!!
        store.recordFailure(identity(), failed.revision, PendingBookMutationFailure.REJECTED, now = 2L)

        val replacement = store.enqueue(identity(), "5", now = 3L)!!
        assertNull(replacement.failure)
        assertEquals(0, replacement.attempts)
    }

    @Test
    fun unreadableFileStartsEmptyAndAcceptsNewEdits(): Unit = runBlocking {
        file.parentFile!!.mkdirs()
        file.writeText("{not json")

        val store = PendingBookMutationStore(file)
        assertTrue(store.mutations.value.isEmpty())
        assertNotNull(store.enqueue(identity(), "4", now = 1L))
        assertEquals("4", PendingBookMutationStore(file).find(identity())?.value)
    }

    @Test
    fun enqueueReportsFailureWhenStorageCannotBeWritten(): Unit = runBlocking {
        directory.mkdirs()
        File(directory, "sync").writeText("occupied")

        val store = PendingBookMutationStore(file)
        assertNull(store.enqueue(identity(), "4", now = 1L))
        assertTrue(store.mutations.value.isEmpty())
    }

    @Test
    fun pendingLookupMatchesBookConnection(): Unit = runBlocking {
        val store = PendingBookMutationStore(file)
        val mutation = store.enqueue(identity(), "4", now = 1L)!!
        val book = Book(
            id = "101",
            title = "Fixture",
            source = BookSource.BOOKORBIT,
            mediaType = AppMediaType.EBOOK,
            connectionId = "connection-a",
        )

        assertTrue(mutation.targets(book))
        assertFalse(mutation.targets(book.copy(connectionId = "connection-b")))
        val account = "http://localhost|reader"
        val name = BookSource.BOOKORBIT.name
        assertTrue(store.hasPending(name, "connection-a", account, "101", PendingBookMutationKind.RATING))
        assertFalse(store.hasPending(name, "connection-a", account, "101", PendingBookMutationKind.READ_STATUS))
        assertFalse(store.hasPending(name, "connection-a", "http://localhost|other", "101", PendingBookMutationKind.RATING))
    }

    @Test
    fun onlyTheConnectionsCurrentAccountSeesItsPendingEdits(): Unit = runBlocking {
        val store = PendingBookMutationStore(file)
        val old = store.enqueue(identity(), "4", now = 1L)!!
        val new = store.enqueue(identity(account = "http://localhost|other"), "1", now = 2L)!!
        val unscoped = store.enqueue(identity(connection = "", account = ""), "3", now = 3L)!!
        val reader = ProviderConnection(
            id = "connection-a",
            source = BookSource.BOOKORBIT,
            name = "BookOrbit",
            serverUrl = "http://localhost/",
            username = "reader",
        )

        assertEquals("http://localhost|reader", reader.pendingBookMutationAccountKey())
        assertEquals(listOf(old), store.mutations.value.forCurrentAccounts(listOf(reader)))
        assertEquals(listOf(old), store.mutations.value.forCurrentAccounts(listOf(reader.copy(enabled = false))))
        assertEquals(listOf(new), store.mutations.value.forCurrentAccounts(listOf(reader.copy(username = "other"))))
        assertEquals(listOf(unscoped), store.mutations.value.forCurrentAccounts(emptyList()))
        assertTrue(store.mutations.value.forCurrentAccounts(listOf(reader.copy(serverUrl = "http://elsewhere"))).isEmpty())
        assertEquals(3, PendingBookMutationStore(file).mutations.value.size)
    }
}
