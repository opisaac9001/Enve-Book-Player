package com.enve.app.playback

import com.enve.app.data.sync.SyncCoordinator
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.PendingProgressPush
import com.enve.core.data.local.PendingProgressPushDao
import com.enve.core.data.local.toBook
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.sync.AudiobookCheckpointOrder
import com.enve.core.data.sync.SyncSnapshot
import java.lang.reflect.Proxy
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackOpenProgressResolverTest {
    private val order = AudiobookCheckpointOrder()
    private val book = Book(id = "a", title = "Audio", source = BookSource.AUDIOBOOKSHELF,
        connectionId = "one", mediaType = AppMediaType.AUDIOBOOK, duration = 1000L,
        currentTime = 120L, readProgress = 0.12f, lastReadTime = 1000L)
    private var stored = book.toCachedBook()
    private var dirty: PendingProgressPush? = null
    private var firstRead = true
    private var afterFirstCacheRead: () -> Unit = {}
    private var beforePendingRead: () -> Unit = {}
    private var remoteWrites = 0
    private var pulls = 0
    private val resolutions = mutableListOf<Boolean>()
    private var pull: suspend () -> SyncCoordinator.OpenSyncResult = { conflict() }
    private val cache = Proxy.newProxyInstance(BookCacheDao::class.java.classLoader,
        arrayOf(BookCacheDao::class.java)) { _, method, args ->
        val values = checkNotNull(args)
        when (method.name) {
            "getByCacheKey" -> {
                assertEquals(book.uniqueKey, values[0])
                val read = stored
                if (firstRead) { firstRead = false; afterFirstCacheRead() }
                read
            }
            "updateAudiobookProgressIfUnchanged" -> {
                remoteWrites++
                val expected = values[0] as CachedBook
                if (stored == expected && dirty == null) {
                    stored = stored.copy(readProgress = values[1] as Float,
                        currentTime = values[2] as Long, lastReadTime = values[3] as Long)
                    1
                } else 0
            }
            else -> error("Unexpected cache method: ${method.name}")
        }
    } as BookCacheDao
    private val pending = Proxy.newProxyInstance(PendingProgressPushDao::class.java.classLoader,
        arrayOf(PendingProgressPushDao::class.java)) { _, method, args ->
        check(method.name == "get")
        assertEquals(book.id, checkNotNull(args)[0])
        beforePendingRead()
        dirty
    } as PendingProgressPushDao
    private val resolver = PlaybackOpenProgressResolver(cache, pending, order,
        { _, _, _ -> pulls++; pull() }, { true }, { true }, { _, _, remote -> resolutions += remote })
    private val writer = PlaybackCheckpointWriter(order) { point ->
        stored = stored.copy(currentTime = point.positionMs / 1000L,
            readProgress = point.positionMs / 1_000_000f, lastReadTime = point.capturedAtMs)
        PlayerProgressService.PersistedPlaybackProgress(stored.toBook(), stored.currentTime, stored.readProgress)
    }
    private val buffer = PlaybackCheckpointBuffer()

    private fun captureZero() = buffer.retain(PlayerProgressService.Checkpoint(book.uniqueKey,
        "book:${book.uniqueKey}", book.id, 0L, 1_000_000L, 2000L, 2000L, order.capture(book.uniqueKey)))

    private fun conflict() = SyncCoordinator.OpenSyncResult.Conflict(
        SyncCoordinator.ProgressOption(0.12f, 1000L, null, 120_000L),
        SyncCoordinator.ProgressOption(0.25f, 3000L, null, 250_000L), "test",
    )

    private fun remote() = SyncCoordinator.OpenSyncResult.Apply(
        SyncSnapshot(percentage = 0.25f, updatedAt = 3000L, positionMs = 250_000L, source = "test"), true,
    )

    @Test
    fun pendingZeroCommittedBetweenCacheAndPendingQueriesReturnsCurrentZero() = runBlocking {
        beforePendingRead = {
            stored = stored.copy(currentTime = 0L, readProgress = 0f, lastReadTime = 2000L)
            dirty = PendingProgressPush(book.id, book.source.name, book.connectionId.orEmpty(),
                AppMediaType.AUDIOBOOK.name, 0f, false, 2000L)
        }
        assertEquals(0L, resolver.resolveStartSeconds(book))
        assertEquals(0, pulls)
        assertEquals(0, remoteWrites)
    }

    @Test
    fun remoteSubmissionBeforeBlockedZeroCannotGainOrderWhenContinuationResumes() = runBlocking {
        withPrompt { dispatcher, result ->
            resolver.resolveConflict(PlaybackProgressConflictChoice.REMOTE)
            val zero = captureZero()
            dispatcher.until { result.isCompleted }
            assertEquals(120L, result.await())
            assertEquals(0, remoteWrites)
            assertTrue(resolutions.isEmpty())
            assertEquals(listOf(zero), buffer.pendingSnapshots())
            assertTrue(buffer.persistCaptured(zero) { writer.persist(it, true) } is PlayerProgressService.SaveResult.Saved)
            assertEquals(0L, stored.currentTime)
            assertTrue(buffer.pendingSnapshots().isEmpty())
        }
    }

    @Test
    fun remoteSubmissionCanReplaceCaptureThatPrecedesSubmission() = runBlocking {
        withPrompt { dispatcher, result ->
            val oldZero = captureZero()
            resolver.resolveConflict(PlaybackProgressConflictChoice.REMOTE)
            dispatcher.until { result.isCompleted }
            assertEquals(250L, result.await())
            assertEquals(250L, stored.currentTime)
            assertEquals(listOf(true), resolutions)
            assertEquals(PlayerProgressService.SaveResult.Superseded,
                buffer.persistCaptured(oldZero) { writer.persist(it, true) })
        }
    }

    @Test
    fun remoteSubmissionCannotReplaceZeroSavedBeforeItsContinuationRuns() = runBlocking {
        withPrompt { dispatcher, result ->
            resolver.resolveConflict(PlaybackProgressConflictChoice.REMOTE)
            assertTrue(writer.persist(captureZero(), true) is PlayerProgressService.SaveResult.Saved)
            dispatcher.until { result.isCompleted }
            assertEquals(0L, result.await())
            assertEquals(0, remoteWrites)
            assertEquals(0L, stored.currentTime)
        }
    }

    @Test
    fun automaticPullThroughFullResolverYieldsToCapturedUnsavedZero() = runBlocking {
        val response = kotlinx.coroutines.CompletableDeferred<Unit>()
        val requested = kotlinx.coroutines.CompletableDeferred<Unit>()
        pull = { requested.complete(Unit); response.await(); remote() }
        val opening = async(start = CoroutineStart.UNDISPATCHED) { resolver.resolveStartSeconds(book) }
        requested.await()
        val zero = captureZero()
        response.complete(Unit)
        assertEquals(120L, opening.await())
        assertEquals(0, remoteWrites)
        assertTrue(buffer.persistCaptured(zero) { writer.persist(it, true) } is PlayerProgressService.SaveResult.Saved)
        assertEquals(0L, stored.currentTime)
    }

    @Test
    fun localWriterCannotCommitInsideCoherentResolverRead() = runBlocking {
        var local: Deferred<PlayerProgressService.SaveResult>? = null
        afterFirstCacheRead = {
            val zero = captureZero()
            local = async(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) { writer.persist(zero, true) }
        }
        beforePendingRead = {
            if (stored.currentTime == 120L) assertFalse(checkNotNull(local).isCompleted)
        }
        pull = { assertTrue(checkNotNull(local).await() is PlayerProgressService.SaveResult.Saved); remote() }
        assertEquals(0L, resolver.resolveStartSeconds(book))
        assertEquals(0L, stored.currentTime)
        assertEquals(0, remoteWrites)
    }

    private suspend fun CoroutineScope.withPrompt(block: suspend (QueuedDispatcher, Deferred<Long>) -> Unit) {
        val observer = launch(start = CoroutineStart.UNDISPATCHED) { resolver.pendingConflict.collect {} }
        val dispatcher = QueuedDispatcher()
        val result = async(dispatcher, start = CoroutineStart.UNDISPATCHED) { resolver.resolveStartSeconds(book) }
        try {
            dispatcher.until { resolver.pendingConflict.value != null }
            assertFalse(result.isCompleted)
            block(dispatcher, result)
        } finally {
            observer.cancelAndJoin()
            if (!result.isCompleted) { result.cancel(); dispatcher.drain() }
        }
    }

    private class QueuedDispatcher : CoroutineDispatcher() {
        private val queue = ConcurrentLinkedQueue<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) { queue.add(block) }
        fun drain() { while (true) (queue.poll() ?: return).run() }
        suspend fun until(condition: () -> Boolean) = withTimeout(5000L) {
            while (!condition()) { drain(); delay(1L) }
        }
    }
}
