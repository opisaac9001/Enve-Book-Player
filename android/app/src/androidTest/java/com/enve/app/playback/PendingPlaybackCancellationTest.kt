package com.enve.app.playback

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaBrowser
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.profiles.DaggerProfileRuntimeComponent
import com.enve.app.profiles.ProfileResources
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.local.toCachedBook
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.FutureTask
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@androidx.annotation.OptIn(UnstableApi::class)
class PendingPlaybackCancellationTest {
    private val nextBook = Book("next-local", "Next local book", source = BookSource.LOCAL, mediaType = AppMediaType.AUDIOBOOK)

    @Test
    fun replacingTheSameBookKeepsTheNewRequestLoading() = fixture { _, queue, _, _ ->
        val book = Book("same-start", "Same book", source = BookSource.LOCAL)
        val firstEntered = CompletableDeferred<Unit>()
        val firstCancelled = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val replacementEntered = CompletableDeferred<Unit>()
        val releaseReplacement = CompletableDeferred<Unit>()
        try {
            queue.launchStart(book) {
                firstEntered.complete(Unit)
                try {
                    awaitCancellation()
                } finally {
                    withContext(NonCancellable) {
                        firstCancelled.complete(Unit)
                        releaseFirst.await()
                    }
                }
            }
            withTimeout(5_000) { firstEntered.await() }
            queue.launchStart(book) {
                replacementEntered.complete(Unit)
                releaseReplacement.await()
            }
            withTimeout(5_000) { firstCancelled.await() }
            releaseFirst.complete(Unit)
            withTimeout(5_000) { replacementEntered.await() }
            assertSame(book, queue.starting.value)
            releaseReplacement.complete(Unit)
            await { queue.starting.value == null }
        } finally {
            releaseFirst.complete(Unit)
            releaseReplacement.complete(Unit)
            queue.cancelPendingStart()
        }
    }

    @Test
    fun multiFileBookResumesAtTheExactSecondTrackBoundary() = fixture { manager, _, browser, audio ->
        val uri = Uri.fromFile(audio).toString()
        withContext(Dispatchers.Main) {
            manager.playMultiTrack(
                listOf(
                    AudioPlaybackManager.TrackInfo(uri, "First chapter", 30_000L),
                    AudioPlaybackManager.TrackInfo(uri, "Second chapter", 30_000L),
                ),
                "boundary-local", "Boundary local book", null, startPositionMs = 30_000L,
            )
        }
        await { withContext(Dispatchers.Main) { browser.isPlaying && browser.currentPosition > 50L } }
        withContext(Dispatchers.Main) {
            assertEquals(1, browser.currentMediaItemIndex)
            assertTrue(browser.currentPosition < 2_000L)
            assertEquals("Second chapter", browser.currentMediaItem?.mediaMetadata?.title.toString())
        }
    }

    @Test
    fun nextBookQueuesBehindPlaybackStillWaitingForItsController() = fixture { manager, queue, browser, audio ->
        withContext(Dispatchers.Main) {
            manager.play(Uri.fromFile(audio).toString(), "current-local", "Current local book", null, null)
            val addNext = FutureTask { runBlocking { queue.addNext(nextBook) } }
            Thread(addNext, "add-next-during-connect").apply { isDaemon = true; start() }
            try {
                assertTrue(addNext.get(5, TimeUnit.SECONDS))
            } finally {
                addNext.cancel(true)
            }
        }
        await { queue.queue.value.any { it.book.uniqueKey == nextBook.uniqueKey } }
        await { withContext(Dispatchers.Main) { browser.isPlaying } }
        withContext(Dispatchers.Main) {
            assertEquals("Current local book", browser.currentMediaItem?.mediaMetadata?.title.toString())
        }
    }

    @Test
    fun cancellingStartBeforeControllerConnectsDoesNotPlayLater() = fixture { manager, queue, browser, audio ->
        withContext(Dispatchers.Main) {
            manager.play(Uri.fromFile(audio).toString(), "cancelled-local", "Cancelled local book", null, null)
            queue.cancelPendingStart()
        }
        awaitControllerCommands(manager, browser)
        withContext(Dispatchers.Main) {
            assertEquals(0, browser.mediaItemCount)
            assertFalse(browser.playWhenReady)
            assertNull(manager.currentBookId)
            assertNull(manager.nowPlayingMetadata.value)
        }
    }

    @Test
    fun cancellingPendingStartKeepsEstablishedBackgroundPlayback() = fixture { manager, queue, browser, audio ->
        withContext(Dispatchers.Main) {
            manager.play(Uri.fromFile(audio).toString(), "playing-local", "Playing local book", null, null)
        }
        await { withContext(Dispatchers.Main) { browser.isPlaying && browser.currentPosition > 200L } }
        withContext(Dispatchers.Main) { queue.cancelPendingStart() }
        delay(300)
        withContext(Dispatchers.Main) {
            assertTrue(browser.isPlaying)
            assertTrue(browser.playWhenReady)
            assertEquals("Playing local book", browser.currentMediaItem?.mediaMetadata?.title.toString())
        }
    }

    @Test
    fun cancellingPostedPlaybackKeepsTheCurrentBook() = fixture { manager, queue, browser, audio ->
        withContext(Dispatchers.Main) {
            manager.play(Uri.fromFile(audio).toString(), "current-local", "Current local book", null, null)
        }
        await { withContext(Dispatchers.Main) { browser.isPlaying && browser.currentPosition > 200L } }
        withContext(Dispatchers.Main) {
            val producer = Thread {
                manager.play(Uri.fromFile(audio).toString(), "cancelled-replacement", "Cancelled replacement", null, null)
                queue.cancelPendingStart()
            }
            producer.start()
            producer.join(2_000)
            assertFalse(producer.isAlive)
        }
        awaitControllerCommands(manager, browser)
        withContext(Dispatchers.Main) {
            assertTrue(browser.isPlaying)
            assertEquals("Current local book", browser.currentMediaItem?.mediaMetadata?.title.toString())
            assertEquals("current-local", manager.currentBookId)
            assertEquals("Current local book", manager.nowPlayingMetadata.value?.title)
        }
    }

    @Test
    fun cancelledProducerCannotSubmitPlaybackAfterCancellation() = fixture { manager, _, browser, audio ->
        val request = Job().apply { cancel() }
        withContext(Dispatchers.Main) {
            manager.connect()
            manager.play(Uri.fromFile(audio).toString(), "cancelled-producer", "Cancelled producer", null, null, requestJob = request)
        }
        awaitControllerCommands(manager, browser)
        withContext(Dispatchers.Main) {
            assertEquals(0, browser.mediaItemCount)
            assertFalse(browser.playWhenReady)
            assertNull(manager.currentBookId)
        }
    }

    @Test
    fun normallyCompletedProducerCanFinishConnecting() = fixture { manager, _, browser, audio ->
        val request = Job()
        withContext(Dispatchers.Main) {
            manager.play(Uri.fromFile(audio).toString(), "completed-producer", "Completed producer", null, null, requestJob = request)
            request.complete()
        }
        await { withContext(Dispatchers.Main) { browser.isPlaying } }
        withContext(Dispatchers.Main) {
            assertEquals("Completed producer", browser.currentMediaItem?.mediaMetadata?.title.toString())
        }
    }

    @Test
    fun replacementStartInvalidatesWorkWaitingForTheController() = fixture { manager, queue, browser, audio ->
        val releaseReplacement = CompletableDeferred<Unit>()
        try {
            withContext(Dispatchers.Main) {
                manager.play(Uri.fromFile(audio).toString(), "superseded-local", "Superseded local book", null, null)
                queue.launchStart(Book("replacement", "Replacement", source = BookSource.LOCAL)) {
                    releaseReplacement.await()
                    manager.play(Uri.fromFile(audio).toString(), "replacement", "Replacement", null, null)
                }
            }
            awaitControllerCommands(manager, browser)
            withContext(Dispatchers.Main) {
                assertEquals(0, browser.mediaItemCount)
                assertFalse(browser.playWhenReady)
            }
            releaseReplacement.complete(Unit)
            await { withContext(Dispatchers.Main) { browser.isPlaying } }
            withContext(Dispatchers.Main) {
                assertEquals("Replacement", browser.currentMediaItem?.mediaMetadata?.title.toString())
            }
        } finally {
            releaseReplacement.complete(Unit)
            queue.cancelPendingStart()
        }
    }

    private fun fixture(
        action: suspend (AudioPlaybackManager, PlaybackQueueCoordinator, MediaBrowser, File) -> Unit,
    ) = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val resources = ProfileResources.open(context, UUID.randomUUID().toString())
        val component = DaggerProfileRuntimeComponent.factory().create(resources)
        component.bookCacheDao().upsert(listOf(nextBook.toCachedBook()))
        val manager = component.audioPlayback()
        val queue = component.playbackQueue()
        val browser = connect(context)
        val audio = File(resources.locations.cacheDirectory, "pending-local.wav")
        writeAudio(audio)
        val volume = withContext(Dispatchers.Main) { browser.volume }
        try {
            withContext(Dispatchers.Main) {
                browser.pause()
                browser.stop()
                browser.clearMediaItems()
                browser.volume = 1f
            }
            action(manager, queue, browser, audio)
        } finally {
            withContext(NonCancellable + Dispatchers.Main) {
                manager.release()
                browser.pause()
                browser.stop()
                browser.clearMediaItems()
                browser.volume = volume
                browser.release()
            }
            resources.close()
            resources.locations.filesDirectory.deleteRecursively()
            resources.locations.cacheDirectory.deleteRecursively()
            resources.locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }

    private suspend fun awaitControllerCommands(manager: AudioPlaybackManager, browser: MediaBrowser) {
        await {
            withContext(Dispatchers.Main) {
                manager.setVolume(0.37f)
                browser.volume == 0.37f
            }
        }
        delay(300)
    }

    private suspend fun connect(context: Context): MediaBrowser {
        val future = withContext(Dispatchers.Main) {
            MediaBrowser.Builder(context, SessionToken(context, ComponentName(context, PlaybackService::class.java)))
                .setApplicationLooper(Looper.getMainLooper())
                .buildAsync()
        }
        return try {
            withContext(Dispatchers.IO) { future.get(15, TimeUnit.SECONDS) }
        } catch (error: Exception) {
            withContext(NonCancellable + Dispatchers.Main) { MediaController.releaseFuture(future) }
            throw error
        }
    }

    private suspend fun await(condition: suspend () -> Boolean) = withTimeout(15_000) {
        while (!condition()) delay(50)
    }

    private fun writeAudio(file: File) {
        val pcmSize = 480_000
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            .put("RIFF".toByteArray()).putInt(36 + pcmSize).put("WAVEfmt ".toByteArray())
            .putInt(16).putShort(1).putShort(1).putInt(8000).putInt(16000)
            .putShort(2).putShort(16).put("data".toByteArray()).putInt(pcmSize).array()
        file.parentFile!!.mkdirs()
        file.outputStream().use { output -> output.write(header); output.write(ByteArray(pcmSize)) }
    }
}
