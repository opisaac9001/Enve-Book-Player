package com.enve.app.data.sync

import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.PendingProgressPush
import com.enve.core.data.local.PendingProgressPushDao
import com.enve.core.data.sync.AudiobookProgressWriteCoordinator
import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import java.lang.reflect.Proxy
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudiobookProgressPushServiceTest {
    private val book = Book(id = "same-id", title = "Audio", source = BookSource.AUDIOBOOKSHELF,
        connectionId = "one", mediaType = AppMediaType.AUDIOBOOK, duration = 1000,
        currentTime = 120, readProgress = 0.12f, lastReadTime = 1000)
    private val rows = mutableMapOf(book.uniqueKey to book.toCachedBook())
    private val pendingRows = mutableMapOf(book.uniqueKey to dirty(1000L, 0.12f))
    private val writerOrder = AudiobookProgressWriteCoordinator()
    private val dao = Proxy.newProxyInstance(BookCacheDao::class.java.classLoader,
        arrayOf(BookCacheDao::class.java)) { _, method, args ->
        val values = checkNotNull(args)
        when (method.name) {
            "getByCacheKey" -> rows[values[0]]
            "acknowledgeAudiobookProgress" -> {
                val expected = values[0] as CachedBook
                val dirty = pendingRows[expected.cacheKey]
                if (sameCheckpoint(expected, rows[expected.cacheKey]) && dirty?.createdAt == values[1] && dirty.percentage == values[2]) {
                    pendingRows.remove(expected.cacheKey)
                    1
                } else 0
            }
            "commitAudiobookCommandIfUnchanged" -> {
                val expected = values[0] as CachedBook
                val dirty = pendingRows[expected.cacheKey]
                val pendingVersion = values[7] as Long?
                if (sameCheckpoint(expected, rows[expected.cacheKey]) && dirty?.createdAt == pendingVersion && (dirty == null || dirty.percentage == values[8])) {
                    rows[expected.cacheKey] = checkNotNull(rows[expected.cacheKey]).copy(
                        readProgress = values[1] as Float, currentTime = values[2] as Long,
                        isFinished = values[3] as Boolean, hideFromContinue = values[4] as Boolean,
                        serverReadStatus = values[5] as String?, lastReadTime = values[6] as Long,
                    )
                    pendingRows.remove(expected.cacheKey)
                    1
                } else 0
            }
            else -> error("Unexpected cache method: ${method.name}")
        }
    } as BookCacheDao
    private val pending = Proxy.newProxyInstance(PendingProgressPushDao::class.java.classLoader,
        arrayOf(PendingProgressPushDao::class.java)) { _, method, args ->
        check(method.name == "get")
        val values = checkNotNull(args)
        pendingRows.values.firstOrNull { it.bookId == values[0] && it.source == values[1] && it.connectionKey == values[2] }
    } as PendingProgressPushDao
    private val rewindTracker = RemoteRewindTracker()
    private val checkpointOrder = com.enve.core.data.sync.AudiobookCheckpointOrder()
    private val service = AudiobookProgressPushService(dao, pending, rewindTracker, writerOrder, checkpointOrder)

    @Test
    fun delayedSuccessCannotReplaceNewerCheckpointAndQueuedPushUsesIt() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val sent = mutableListOf<Long>()
        val first = async(start = CoroutineStart.UNDISPATCHED) {
            service.push(book, 120, 0.12f) { _, position, _ ->
                sent += position
                release.await()
                Result.success(Unit)
            }
        }
        val newer = checkpoint(240, 2000)
        rows[book.uniqueKey] = newer
        val second = async(start = CoroutineStart.UNDISPATCHED) {
            service.push(book, 120, 0.12f) { _, position, _ ->
                sent += position
                Result.success(Unit)
            }
        }
        assertFalse(second.isCompleted)
        release.complete(Unit)
        assertTrue(first.await().isSuccess)
        assertTrue(second.await().isSuccess)
        assertEquals(listOf(120L, 240L), sent)
        assertEquals(newer, rows[book.uniqueKey])
    }

    @Test
    fun explicitRewindToZeroWinsOverOlderForwardPayload() = runBlocking {
        val rewind = checkpoint(0, 2000)
        rows[book.uniqueKey] = rewind
        service.push(book, 240, 0.24f) { _, position, progress ->
            assertEquals(0L, position)
            assertEquals(0f, progress)
            Result.success(Unit)
        }
        assertEquals(rewind, rows[book.uniqueKey])
    }

    @Test
    fun failureKeepsTheCheckpointAvailableForReplay() = runBlocking {
        val before = rows[book.uniqueKey]
        val result = service.push(book, 120, 0.12f) { _, _, _ -> Result.failure(IllegalStateException("Offline")) }
        assertTrue(result.isFailure)
        assertEquals(before, rows[book.uniqueKey])
    }

    @Test
    fun anotherConnectionCanPushWhileTheFirstIsWaiting() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val first = async(start = CoroutineStart.UNDISPATCHED) {
            service.push(book, 120, 0.12f) { _, _, _ -> release.await(); Result.success(Unit) }
        }
        val other = book.copy(connectionId = "two", currentTime = 600, readProgress = 0.6f)
        rows[other.uniqueKey] = other.toCachedBook()
        service.push(other, 120, 0.12f) { checkpoint, position, _ ->
            assertEquals("two", checkpoint.connectionId)
            assertEquals(600L, position)
            Result.success(Unit)
        }
        release.complete(Unit)
        assertTrue(first.await().isSuccess)
    }

    @Test
    fun successfulPushLeavesSnapshotUnchangedForPendingAcknowledgement() = runBlocking {
        val before = rows[book.uniqueKey]
        assertTrue(service.push(book, 120, 0.12f) { _, _, _ -> Result.success(Unit) }.isSuccess)
        assertEquals(before, rows[book.uniqueKey])
    }

    @Test
    fun sourcesWithoutConnectionsKeepIndependentCheckpoints() = runBlocking {
        val abs = book.copy(connectionId = null)
        val other = abs.copy(source = BookSource.GRIMMORY, currentTime = 600, readProgress = 0.6f)
        rows[abs.uniqueKey] = abs.toCachedBook()
        rows[other.uniqueKey] = other.toCachedBook()
        service.push(abs, 900, 0.9f) { checkpoint, position, _ ->
            assertEquals(BookSource.AUDIOBOOKSHELF, checkpoint.source)
            assertEquals(120L, position)
            Result.success(Unit)
        }
        service.push(other, 900, 0.9f) { checkpoint, position, _ ->
            assertEquals(BookSource.GRIMMORY, checkpoint.source)
            assertEquals(600L, position)
            Result.success(Unit)
        }
        assertEquals(120L, rows[abs.uniqueKey]!!.currentTime)
        assertEquals(600L, rows[other.uniqueKey]!!.currentTime)
    }

    @Test
    fun revokedQueuedWriteDoesNotReachTheProvider() = runBlocking {
        var called = false
        val result = service.push(book, 120, 0.12f, canWrite = { false }) { _, _, _ ->
            called = true
            Result.success(Unit)
        }
        assertTrue(result.isSuccess)
        assertFalse(called)
    }

    @Test
    fun successAcknowledgesOnlyTheSentCheckpoint() = runBlocking {
        service.push(book, 120, 0.12f) { _, _, _ -> Result.success(Unit) }
        assertNull(pendingRows[book.uniqueKey])
        assertEquals(120L, rows[book.uniqueKey]!!.currentTime)
    }

    @Test
    fun delayedSuccessKeepsNewerPendingVersion() = runBlocking {
        service.push(book, 120, 0.12f) { _, _, _ ->
            rows[book.uniqueKey] = checkpoint(0L, 2000L)
            pendingRows[book.uniqueKey] = dirty(2001L, 0f)
            Result.success(Unit)
        }
        assertEquals(0L, rows[book.uniqueKey]!!.currentTime)
        assertEquals(2001L, pendingRows[book.uniqueKey]!!.createdAt)
    }

    @Test
    fun pendingVersionChangeWithoutCacheChangeCannotBeAcknowledged() = runBlocking {
        service.push(book, 120, 0.12f) { _, _, _ ->
            pendingRows[book.uniqueKey] = dirty(2000L, 0.12f)
            Result.success(Unit)
        }
        assertEquals(2000L, pendingRows[book.uniqueKey]!!.createdAt)
    }

    @Test
    fun replayAndPlaybackReportingLeaveAcknowledgementToTheirOwner() = runBlocking {
        service.push(book, 120, 0.12f, acknowledgePending = false) { _, _, _ -> Result.success(Unit) }
        assertNotNull(pendingRows[book.uniqueKey])
    }

    @Test
    fun stateOnlyPlaybackReportDoesNotInventProgressEcho() = runBlocking {
        service.push(book, 120L, 0.12f, acknowledgePending = false, recordOutboundEcho = false) { _, _, _ -> Result.success(Unit) }
        assertEquals(RemoteRewindVerdict.UNCONFIRMED, rewindTracker.assess(
            RemoteProgressScope.of(book, "provider"),
            RemoteProgressObservation(0.12f, 120_000L, observedAt = System.currentTimeMillis()),
            localPercentage = 0.24f,
        ))
        assertNotNull(pendingRows[book.uniqueKey])
    }

    @Test
    fun failedPushKeepsDirtyRow() = runBlocking {
        service.push(book, 120, 0.12f) { _, _, _ -> Result.failure(IllegalStateException("Offline")) }
        assertNotNull(pendingRows[book.uniqueKey])
    }

    @Test
    fun queuedWriteRechecksGateAfterWaiting() = runBlocking {
        var enabled = true
        var called = false
        val release = CompletableDeferred<Unit>()
        val first = async(start = CoroutineStart.UNDISPATCHED) {
            service.push(book, 120, 0.12f) { _, _, _ -> release.await(); Result.success(Unit) }
        }
        val waiting = async(start = CoroutineStart.UNDISPATCHED) {
            service.push(book, 120, 0.12f, canWrite = { enabled }) { _, _, _ -> called = true; Result.success(Unit) }
        }
        enabled = false
        release.complete(Unit)
        first.await()
        assertTrue(waiting.await().isSuccess)
        assertFalse(called)
    }

    @Test
    fun revocationDuringRequestDoesNotAcknowledgeUnsentPendingProgress() = runBlocking {
        var enabled = true
        service.push(book, 120L, 0.12f, canWrite = { enabled }) { _, _, _ ->
            enabled = false
            Result.success(Unit)
        }
        assertNotNull(pendingRows[book.uniqueKey])
    }

    @Test
    fun sessionCloseUsesLatestCheckpointAfterNormalPushCompletes() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val sent = mutableListOf<Long>()
        val normal = async(start = CoroutineStart.UNDISPATCHED) {
            service.push(book, 120, 0.12f) { _, pos, _ -> sent += pos; release.await(); Result.success(Unit) }
        }
        val close = async(start = CoroutineStart.UNDISPATCHED) {
            service.push(book, 120, 0.12f) { _, pos, _ -> sent += pos; Result.success(Unit) }
        }
        rows[book.uniqueKey] = checkpoint(0L, 2000L)
        pendingRows[book.uniqueKey] = dirty(2000L, 0f)
        release.complete(Unit)
        normal.await()
        close.await()
        assertEquals(listOf(120L, 0L), sent)
        assertNull(pendingRows[book.uniqueKey])
    }

    @Test
    fun resetAndCompletionAreOrderedAfterOldPushAndBeforeNextPush() = runBlocking {
        for (finished in listOf(false, true)) {
            rows[book.uniqueKey] = checkpoint(120L, 1000L)
            pendingRows[book.uniqueKey] = dirty(1000L, 0.12f)
            val release = CompletableDeferred<Unit>()
            val sent = mutableListOf<Long>()
            val old = async(start = CoroutineStart.UNDISPATCHED) {
                service.push(book, 120L, 0.12f) { _, pos, _ -> sent += pos; release.await(); Result.success(Unit) }
            }
            val command = async(start = CoroutineStart.UNDISPATCHED) {
                service.command(book, { true }, {
                    AudiobookProgressPushService.Command(if (finished) 1f else 0f, if (finished) 1000L else 0L, finished, false, if (finished) "READ" else null)
                }) { sent += if (finished) 1000L else 0L; Result.success(Unit) }
            }
            assertFalse(command.isCompleted)
            release.complete(Unit)
            old.await()
            command.await()
            service.push(book, 120L, 0.12f) { _, pos, _ -> sent += pos; Result.success(Unit) }
            assertEquals(listOf(120L, if (finished) 1000L else 0L, if (finished) 1000L else 0L), sent)
            assertEquals(finished, rows[book.uniqueKey]!!.isFinished)
        }
    }

    @Test
    fun delayedCommandCannotOverwriteNewSeek() = runBlocking {
        service.command(book, { true }, { AudiobookProgressPushService.Command(1f, 1000L, true, false, "READ") }) {
            rows[book.uniqueKey] = checkpoint(0L, 2000L)
            pendingRows[book.uniqueKey] = dirty(2000L, 0f)
            Result.success(Unit)
        }
        assertEquals(0L, rows[book.uniqueKey]!!.currentTime)
        assertFalse(rows[book.uniqueKey]!!.isFinished)
        assertNotNull(pendingRows[book.uniqueKey])
    }

    @Test
    fun podcastSessionRetainsItsTypeAndLatestZeroCheckpoint() = runBlocking {
        val episode = book.copy(mediaType = AppMediaType.PODCAST, episodeId = "episode", currentTime = 0L, readProgress = 0f, lastReadTime = 2000L)
        rows[episode.uniqueKey] = episode.toCachedBook()
        pendingRows[episode.uniqueKey] = dirty(2000L, 0f)
        service.push(episode, 120L, 0.12f) { checkpoint, position, percentage ->
            assertEquals(AppMediaType.PODCAST, checkpoint.mediaType)
            assertEquals("episode", checkpoint.episodeId)
            assertEquals(0L, position)
            assertEquals(0f, percentage)
            Result.success(Unit)
        }
        assertNull(pendingRows[episode.uniqueKey])
    }

    @Test
    fun resetCommitSupersedesEarlierCapturedPlayback() = runBlocking {
        val oldCapture = checkpointOrder.capture(book.uniqueKey)
        service.command(book, { true }, { AudiobookProgressPushService.Command(0f, 0L, false, false, null) }) {
            Result.success(Unit)
        }
        checkpointOrder.serialized { assertTrue(it.isSuperseded(book.uniqueKey, oldCapture)) }
        assertEquals(0L, rows[book.uniqueKey]!!.currentTime)
    }

    @Test
    fun delayedCompletionCannotReplaceNewLocalIntentWithUnchangedStorageTuple() = runBlocking {
        service.command(book, { true }, { AudiobookProgressPushService.Command(1f, 1000L, true, false, "READ") }) {
            val freshCapture = checkpointOrder.capture(book.uniqueKey)
            checkpointOrder.serialized { it.recordApplied(book.uniqueKey, freshCapture) }
            Result.success(Unit)
        }
        assertEquals(120L, rows[book.uniqueKey]!!.currentTime)
        assertFalse(rows[book.uniqueKey]!!.isFinished)
        assertNotNull(pendingRows[book.uniqueKey])
    }

    private fun dirty(version: Long, percentage: Float) = PendingProgressPush(
        book.id, book.source.name, book.connectionId.orEmpty(), "AUDIOBOOK", percentage, false, version,
    )

    private fun sameCheckpoint(a: CachedBook, b: CachedBook?): Boolean = b != null &&
        a.currentTime == b.currentTime && a.readProgress == b.readProgress && a.lastReadTime == b.lastReadTime &&
        a.isFinished == b.isFinished && a.serverReadStatus == b.serverReadStatus

    private fun checkpoint(position: Long, timestamp: Long): CachedBook =
        book.copy(currentTime = position, readProgress = position / 1000f, lastReadTime = timestamp).toCachedBook()
}
