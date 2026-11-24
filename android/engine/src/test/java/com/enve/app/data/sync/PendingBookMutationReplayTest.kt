package com.enve.app.data.sync

import com.enve.core.data.local.PendingBookMutation
import com.enve.core.data.local.PendingBookMutationFailure
import com.enve.core.data.local.PendingBookMutationKind
import com.enve.core.data.local.PendingBookMutationStore
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.provider.ProviderMutationException
import com.enve.engine.library.BookEditOutcome
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files

class PendingBookMutationReplayTest {
    private val directory: File = Files.createTempDirectory("pending-book-replay").toFile()
    private val file = File(directory, "pending_book_mutations.json")
    private var now = 1_000_000L

    private val book = Book(
        id = "101",
        title = "Fixture",
        source = BookSource.BOOKORBIT,
        mediaType = AppMediaType.EBOOK,
        connectionId = "connection-a",
    )

    private class FakeTransport : PendingBookMutationTransport {
        override var syncEnabled = true
        var account = "http://localhost|reader"
        var target = PendingBookMutationTarget.READY
        var respond: suspend (PendingBookMutation) -> Result<Unit> = { Result.success(Unit) }
        val applied = mutableListOf<Pair<PendingBookMutationKind, String>>()
        val sent = mutableListOf<PendingBookMutation>()

        override fun accountKey(book: Book): String = account
        override fun target(mutation: PendingBookMutation): PendingBookMutationTarget =
            if (mutation.accountKey != account) PendingBookMutationTarget.UNAVAILABLE else target

        override suspend fun applyLocally(book: Book, kind: PendingBookMutationKind, value: String) {
            applied += kind to value
        }

        override suspend fun send(mutation: PendingBookMutation): Result<Unit> {
            sent += mutation
            return respond(mutation)
        }
    }

    private val transport = FakeTransport()

    private fun replay(store: PendingBookMutationStore = PendingBookMutationStore(file)) =
        store to PendingBookMutationReplay(store, transport) { now }

    @After
    fun tearDown() {
        directory.deleteRecursively()
    }

    @Test
    fun successfulEditIsAppliedLocallySentAndAcknowledged(): Unit = runBlocking {
        val (store, replay) = replay()

        assertEquals(BookEditOutcome.SYNCED, replay.submit(book, PendingBookMutationKind.RATING, "4"))
        assertEquals(listOf(PendingBookMutationKind.RATING to "4"), transport.applied)
        assertEquals(listOf("4"), transport.sent.map { it.value })
        assertTrue(store.mutations.value.isEmpty())
    }

    @Test
    fun editIsPersistedBeforeTheNetworkCallStarts(): Unit = runBlocking {
        val (store, replay) = replay()
        var persistedDuringSend: String? = null
        transport.respond = {
            persistedDuringSend = PendingBookMutationStore(file).mutations.value.singleOrNull()?.value
            Result.success(Unit)
        }

        replay.submit(book, PendingBookMutationKind.READ_STATUS, "ON_HOLD")
        assertEquals("ON_HOLD", persistedDuringSend)
        assertTrue(store.mutations.value.isEmpty())
    }

    @Test
    fun transientFailureKeepsTheEditAndReportsWaiting(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.respond = { Result.failure(IOException("offline")) }

        assertEquals(BookEditOutcome.WAITING, replay.submit(book, PendingBookMutationKind.RATING, "5"))
        val pending = store.mutations.value.single()
        assertEquals("5", pending.value)
        assertEquals(PendingBookMutationFailure.TRANSIENT, pending.failure)
        assertEquals(1, pending.attempts)
    }

    @Test
    fun relaunchReplaysRetainedEditOnceBackoffHasElapsed(): Unit = runBlocking {
        val (_, first) = replay()
        transport.respond = { Result.failure(IOException("offline")) }
        first.submit(book, PendingBookMutationKind.READ_STATUS, "READ")

        transport.respond = { Result.success(Unit) }
        val (relaunchedStore, relaunched) = replay()
        assertEquals(0, relaunched.replay(PendingBookMutationTrigger.START))
        assertEquals(1, relaunchedStore.mutations.value.size)

        now += PendingBookMutationPolicy.retryDelayMs(1)
        assertEquals(1, relaunched.replay(PendingBookMutationTrigger.START))
        assertTrue(relaunchedStore.mutations.value.isEmpty())
        assertEquals(listOf("READ", "READ"), transport.sent.map { it.value })
    }

    @Test
    fun reconnectRetriesTransientFailureImmediately(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.respond = { Result.failure(IOException("offline")) }
        replay.submit(book, PendingBookMutationKind.RATING, "3")
        transport.respond = { Result.success(Unit) }

        assertEquals(0, replay.replay(PendingBookMutationTrigger.FOREGROUND))
        assertEquals(1, replay.replay(PendingBookMutationTrigger.NETWORK))
        assertTrue(store.mutations.value.isEmpty())
    }

    @Test
    fun reconnectRetriesStopAtTheAttemptCap(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.respond = { Result.failure(IOException("offline")) }
        replay.submit(book, PendingBookMutationKind.RATING, "3")
        repeat(PendingBookMutationPolicy.MAX_AUTOMATIC_ATTEMPTS + 4) { replay.replay(PendingBookMutationTrigger.NETWORK) }

        assertEquals(PendingBookMutationPolicy.MAX_AUTOMATIC_ATTEMPTS, transport.sent.size)
        assertEquals(1, store.mutations.value.size)
    }

    @Test
    fun permissionFailureIsRejectedAndNotRetriedAutomatically(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.respond = { Result.failure(ProviderMutationException(403, "HTTP 403")) }

        assertEquals(BookEditOutcome.REJECTED, replay.submit(book, PendingBookMutationKind.RATING, "2"))
        now += 24L * 60L * 60L * 1_000L
        replay.replay(PendingBookMutationTrigger.NETWORK)
        replay.replay(PendingBookMutationTrigger.FOREGROUND)
        assertEquals(1, transport.sent.size)
        assertEquals(PendingBookMutationFailure.REJECTED, store.mutations.value.single().failure)
    }

    @Test
    fun accountChangedDuringSendIsRecordedAsUnavailable(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.respond = {
            transport.account = "http://localhost|someone-else"
            Result.failure(IllegalStateException("Requested provider connection is unavailable"))
        }

        assertEquals(BookEditOutcome.UNAVAILABLE, replay.submit(book, PendingBookMutationKind.RATING, "4"))
        assertEquals(PendingBookMutationFailure.UNAVAILABLE, store.mutations.value.single().failure)
    }

    @Test
    fun authFailureIsNotRetriedOnReconnectOrHotLooped(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.respond = { Result.failure(ProviderMutationException(401, "HTTP 401")) }

        assertEquals(BookEditOutcome.NEEDS_SIGN_IN, replay.submit(book, PendingBookMutationKind.RATING, "2"))
        now += 60_000L
        assertEquals(0, replay.replay(PendingBookMutationTrigger.NETWORK))
        assertEquals(0, replay.replay(PendingBookMutationTrigger.FOREGROUND))
        assertEquals(1, transport.sent.size)
        assertEquals(PendingBookMutationFailure.AUTH, store.mutations.value.single().failure)

        transport.respond = { Result.success(Unit) }
        assertEquals(BookEditOutcome.SYNCED, replay.retry(store.mutations.value.single().identity))
    }

    @Test
    fun signedOutConnectionIsMarkedWithoutSending(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.target = PendingBookMutationTarget.NEEDS_SIGN_IN

        assertEquals(BookEditOutcome.NEEDS_SIGN_IN, replay.submit(book, PendingBookMutationKind.RATING, "2"))
        assertTrue(transport.sent.isEmpty())
        assertEquals(1, store.mutations.value.single().attempts)
        replay.replay(PendingBookMutationTrigger.MANUAL)
        assertEquals(1, store.mutations.value.single().attempts)
    }

    @Test
    fun rejectedEditStaysVisibleAndOnlyManualRetrySendsAgain(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.respond = { Result.failure(ProviderMutationException(404, "HTTP 404")) }

        assertEquals(BookEditOutcome.REJECTED, replay.submit(book, PendingBookMutationKind.READ_STATUS, "SKIMMED"))
        now += 24L * 60L * 60L * 1_000L
        replay.replay(PendingBookMutationTrigger.START)
        replay.replay(PendingBookMutationTrigger.NETWORK)
        assertEquals(1, transport.sent.size)

        replay.retry(store.mutations.value.single().identity)
        assertEquals(2, transport.sent.size)
        assertEquals(1, store.mutations.value.size)
    }

    @Test
    fun automaticRetriesStopAfterTheAttemptCap(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.respond = { Result.failure(IOException("offline")) }
        replay.submit(book, PendingBookMutationKind.RATING, "1")
        repeat(PendingBookMutationPolicy.MAX_AUTOMATIC_ATTEMPTS + 4) {
            now += 2L * 60L * 60L * 1_000L
            replay.replay(PendingBookMutationTrigger.FOREGROUND)
        }

        assertEquals(PendingBookMutationPolicy.MAX_AUTOMATIC_ATTEMPTS, transport.sent.size)
        assertEquals(1, store.mutations.value.size)
    }

    @Test
    fun cancellationPropagatesAndLeavesTheEditQueuedWithoutFailure(): Unit = runBlocking {
        val (store, replay) = replay()
        val cancellation = CancellationException("cancelled")
        transport.respond = { throw cancellation }

        assertSame(cancellation, assertThrows(CancellationException::class.java) {
            runBlocking { replay.submit(book, PendingBookMutationKind.RATING, "4") }
        })
        val pending = store.mutations.value.single()
        assertNull(pending.failure)
        assertEquals(0, pending.attempts)
    }

    @Test
    fun editMadeWhileOlderRevisionIsInFlightIsNotAcknowledgedByIt(): Unit = runBlocking {
        val (store, replay) = replay()
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        transport.respond = { mutation ->
            if (mutation.value == "2") {
                firstStarted.complete(Unit)
                releaseFirst.await()
            }
            Result.success(Unit)
        }

        val first = async { replay.submit(book, PendingBookMutationKind.RATING, "2") }
        firstStarted.await()
        val second = async { replay.submit(book, PendingBookMutationKind.RATING, "5") }
        while (store.mutations.value.singleOrNull()?.value != "5") kotlinx.coroutines.yield()
        releaseFirst.complete(Unit)

        first.await()
        assertEquals(BookEditOutcome.SYNCED, second.await())
        assertEquals(listOf("2", "5"), transport.sent.map { it.value })
        assertTrue(store.mutations.value.isEmpty())
    }

    @Test
    fun editForAnotherAccountOnTheSameConnectionIsNeverSent(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.respond = { Result.failure(IOException("offline")) }
        replay.submit(book, PendingBookMutationKind.RATING, "4")
        transport.sent.clear()

        transport.account = "http://localhost|someone-else"
        transport.respond = { Result.success(Unit) }
        now += 2L * 60L * 60L * 1_000L
        assertEquals(0, replay.replay(PendingBookMutationTrigger.START))
        assertTrue(transport.sent.isEmpty())
        assertEquals(PendingBookMutationFailure.UNAVAILABLE, store.mutations.value.single().failure)

        transport.account = "http://localhost|reader"
        assertEquals(1, replay.replay(PendingBookMutationTrigger.FOREGROUND))
    }

    @Test
    fun disabledServerSyncSavesOnDeviceWithoutQueueing(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.syncEnabled = false

        assertEquals(BookEditOutcome.LOCAL_ONLY, replay.submit(book, PendingBookMutationKind.RATING, "4"))
        assertEquals(1, transport.applied.size)
        assertTrue(transport.sent.isEmpty())
        assertTrue(store.mutations.value.isEmpty())
    }

    @Test
    fun ratingAndStatusForOneBookAreIndependent(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.respond = { mutation ->
            if (mutation.kind == PendingBookMutationKind.RATING) Result.failure(IOException("offline")) else Result.success(Unit)
        }

        replay.submit(book, PendingBookMutationKind.RATING, "4")
        assertEquals(BookEditOutcome.SYNCED, replay.submit(book, PendingBookMutationKind.READ_STATUS, "READING"))
        assertEquals(PendingBookMutationKind.RATING, store.mutations.value.single().kind)
    }

    @Test
    fun httpStatusesMapToTruthfulFailureKinds() {
        assertEquals(PendingBookMutationFailure.AUTH, PendingBookMutationPolicy.classify(401))
        assertEquals(PendingBookMutationFailure.REJECTED, PendingBookMutationPolicy.classify(403))
        assertEquals(PendingBookMutationFailure.TRANSIENT, PendingBookMutationPolicy.classify(429))
        assertEquals(PendingBookMutationFailure.TRANSIENT, PendingBookMutationPolicy.classify(503))
        assertEquals(PendingBookMutationFailure.REJECTED, PendingBookMutationPolicy.classify(422))
        assertEquals(
            PendingBookMutationFailure.REJECTED,
            PendingBookMutationPolicy.classify(UnsupportedOperationException("unsupported")),
        )
        assertEquals(30_000L, PendingBookMutationPolicy.retryDelayMs(1))
        assertEquals(60L * 60L * 1_000L, PendingBookMutationPolicy.retryDelayMs(40))
    }

    @Test
    fun catalogRefreshCannotEraseAPendingRatingOrStatus(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.respond = { Result.failure(IOException("offline")) }
        replay.submit(book, PendingBookMutationKind.RATING, "5")
        replay.submit(book, PendingBookMutationKind.READ_STATUS, "READ")

        val local = book.copy(personalRating = 5f, serverReadStatus = "READ", isFinished = true).toCachedBook(nowMs = 1L)
        val server = book.copy(personalRating = 2f, serverReadStatus = "READING").toCachedBook(nowMs = 2L)
        val accounts = listOf(connection("reader"))
        val merged = server.preservingPendingEdits(local, store.mutations.value, accounts)
        assertEquals(5f, merged.personalRating)
        assertEquals("READ", merged.serverReadStatus)
        assertTrue(merged.isFinished)

        val firstSight = server.preservingPendingEdits(null, store.mutations.value, accounts)
        assertEquals("READ", firstSight.serverReadStatus)
        assertTrue(firstSight.isFinished)
        assertFalse(firstSight.inProgress)

        val otherConnection = server.copy(connectionId = "connection-b")
        assertEquals(2f, otherConnection.preservingPendingEdits(null, store.mutations.value, accounts).personalRating)
        assertEquals(server, server.preservingPendingEdits(local, emptyList(), accounts))
    }

    @Test
    fun pendingEditsFromThePreviousAccountNeverOverlayTheNewAccountsCatalog(): Unit = runBlocking {
        val (store, replay) = replay()
        transport.respond = { Result.failure(IOException("offline")) }
        replay.submit(book, PendingBookMutationKind.RATING, "5")
        replay.submit(book, PendingBookMutationKind.READ_STATUS, "READ")
        transport.account = "http://localhost|newcomer"
        replay.submit(book, PendingBookMutationKind.RATING, "1")

        val server = book.copy(personalRating = 2f, serverReadStatus = "READING").toCachedBook(nowMs = 2L)
        val newAccount = server.preservingPendingEdits(null, store.mutations.value, listOf(connection("newcomer")))
        assertEquals(1f, newAccount.personalRating)
        assertEquals("READING", newAccount.serverReadStatus)
        assertFalse(newAccount.isFinished)

        val disabledOldAccount = listOf(connection("reader").copy(enabled = false))
        val oldAccount = server.preservingPendingEdits(null, store.mutations.value, disabledOldAccount)
        assertEquals(5f, oldAccount.personalRating)
        assertEquals("READ", oldAccount.serverReadStatus)

        assertEquals(server, server.preservingPendingEdits(null, store.mutations.value, emptyList()))
        assertEquals(3, PendingBookMutationStore(file).mutations.value.size)
    }

    private fun connection(username: String) = ProviderConnection(
        id = "connection-a",
        source = BookSource.BOOKORBIT,
        name = "BookOrbit",
        serverUrl = "http://localhost/",
        username = username,
    )
}
