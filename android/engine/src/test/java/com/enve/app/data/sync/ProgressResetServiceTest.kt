package com.enve.app.data.sync

import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.PendingProgressPush
import com.enve.core.data.local.PendingProgressPushDao
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.sync.AudiobookCheckpointOrder
import com.enve.core.data.sync.AudiobookProgressWriteCoordinator
import java.io.IOException
import java.lang.reflect.Proxy
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProgressResetServiceTest {
    private val audiobook = Book(id = "audio", title = "Audio", source = BookSource.AUDIOBOOKSHELF, connectionId = "abs",
        mediaType = AppMediaType.AUDIOBOOK, duration = 3600, currentTime = 900, readProgress = 0.25f, lastReadTime = 1000)
    private val ebook = Book(id = "ebook", title = "Ebook", source = BookSource.GRIMMORY, connectionId = "grim",
        mediaType = AppMediaType.EBOOK, readProgress = 0.4f, epubProgress = 0.4f, isFinished = true,
        epubLocator = """{"href":"chapter-9.xhtml"}""", lastReadTime = 1000)
    private val rows = mutableMapOf(audiobook.uniqueKey to audiobook.toCachedBook(), ebook.uniqueKey to ebook.toCachedBook())
    private val pendingRows = mutableMapOf<String, PendingProgressPush>()

    private fun row(bookId: String, connectionId: String?): Pair<String, CachedBook>? =
        rows.entries.firstOrNull { it.value.id == bookId && it.value.connectionId == connectionId }?.toPair()

    private val dao = Proxy.newProxyInstance(BookCacheDao::class.java.classLoader, arrayOf(BookCacheDao::class.java)) { _, method, args ->
        val values = checkNotNull(args)
        when (method.name) {
            "getByCacheKey" -> rows[values[0]]
            "commitAudiobookCommandIfUnchanged" -> {
                val expected = values[0] as CachedBook
                rows[expected.cacheKey] = expected.copy(readProgress = values[1] as Float, currentTime = values[2] as Long,
                    isFinished = values[3] as Boolean, hideFromContinue = values[4] as Boolean)
                1
            }
            "updateUnifiedProgress" -> row(values[0] as String, values[1] as String?)?.let { (key, cached) ->
                rows[key] = cached.copy(readProgress = values[2] as Float, epubProgress = values[2] as Float,
                    currentTime = values[3] as Long, epubLocator = (values[4] as String?) ?: cached.epubLocator)
                1
            } ?: 0
            "updateEpubProgress" -> row(values[0] as String, values[1] as String?)?.let { (key, cached) ->
                rows[key] = cached.copy(epubLocator = values[2] as String?, epubProgress = values[3] as Float)
                Unit
            } ?: Unit
            "updateFinishedStatus" -> row(values[0] as String, values[1] as String?)?.let { (key, cached) ->
                rows[key] = cached.copy(isFinished = values[2] as Boolean)
                Unit
            } ?: Unit
            else -> error("Unexpected cache method: ${method.name}")
        }
    } as BookCacheDao

    private val pending = Proxy.newProxyInstance(PendingProgressPushDao::class.java.classLoader,
        arrayOf(PendingProgressPushDao::class.java)) { _, method, args ->
        val values = checkNotNull(args)
        when (method.name) {
            "get" -> pendingRows.values.firstOrNull { it.bookId == values[0] && it.source == values[1] && it.connectionKey == values[2] }
            "upsert" -> {
                val item = values[0] as PendingProgressPush
                pendingRows["${item.connectionKey}:${item.bookId}"] = item
                Unit
            }
            else -> error("Unexpected pending method: ${method.name}")
        }
    } as PendingProgressPushDao

    private val service = ProgressResetService(
        dao,
        pending,
        AudiobookProgressPushService(dao, pending, RemoteRewindTracker(), AudiobookProgressWriteCoordinator(), AudiobookCheckpointOrder()),
    )

    @Test
    fun offlineEbookResetStillClearsLocalProgressAndQueuesServerReset() = runBlocking {
        val result = service.reset(ebook, syncEnabled = true) { Result.failure(IOException("Offline")) }

        assertTrue(result.isFailure)
        val local = rows.getValue(ebook.uniqueKey)
        assertEquals(0f, local.readProgress)
        assertEquals(0f, local.epubProgress)
        assertNull(local.epubLocator)
        assertFalse(local.isFinished)
        val queued = pendingRows.getValue(ebook.uniqueKey)
        assertEquals(AppMediaType.EBOOK.name, queued.mediaType)
        assertEquals(0f, queued.percentage)
        assertFalse(queued.isFinished)
    }

    @Test
    fun offlineAudiobookResetStillClearsLocalPositionAndQueuesServerReset() = runBlocking {
        val result = service.reset(audiobook, syncEnabled = true) { throw IOException("Offline") }

        assertTrue(result.isFailure)
        val local = rows.getValue(audiobook.uniqueKey)
        assertEquals(0L, local.currentTime)
        assertEquals(0f, local.readProgress)
        assertEquals(AppMediaType.AUDIOBOOK.name, pendingRows.getValue(audiobook.uniqueKey).mediaType)
    }

    @Test
    fun successfulServerResetLeavesNothingQueued() = runBlocking {
        val result = service.reset(audiobook, syncEnabled = true) { Result.success(Unit) }

        assertTrue(result.isSuccess)
        assertEquals(0L, rows.getValue(audiobook.uniqueKey).currentTime)
        assertTrue(pendingRows.isEmpty())
    }

    @Test
    fun disabledServerSyncResetsLocallyWithoutCallingTheServer() = runBlocking {
        var called = false
        val result = service.reset(ebook, syncEnabled = false) { called = true; Result.success(Unit) }

        assertTrue(result.isSuccess)
        assertFalse(called)
        assertEquals(0f, rows.getValue(ebook.uniqueKey).readProgress)
        assertTrue(pendingRows.isEmpty())
    }

    @Test
    fun localLibraryFailureIsNotQueued() = runBlocking {
        val local = ebook.copy(id = "local", source = BookSource.LOCAL, connectionId = null)
        rows[local.uniqueKey] = local.toCachedBook()

        service.reset(local, syncEnabled = true) { Result.failure(IOException("Unavailable")) }

        assertEquals(0f, rows.getValue(local.uniqueKey).readProgress)
        assertTrue(pendingRows.isEmpty())
    }
}
