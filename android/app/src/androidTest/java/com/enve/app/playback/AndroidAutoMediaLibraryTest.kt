package com.enve.app.playback

import android.content.ComponentName
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaConstants
import androidx.media3.session.MediaBrowser
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import androidx.media3.session.SessionToken
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.data.model.Chapter
import com.enve.engine.playback.PlaybackAutomationContract
import dagger.hilt.android.EntryPointAccessors
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking

@RunWith(AndroidJUnit4::class)
@androidx.annotation.OptIn(UnstableApi::class)
class AndroidAutoMediaLibraryTest {
    @Test
    fun artworkProviderServesCachedJpeg() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val directory = File(context.cacheDir, AutoArtworkProvider.CACHE_DIRECTORY).apply { mkdirs() }
        val artwork = File(directory, "a".repeat(64) + ".jpg")
        val expected = byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte(), 0xd9.toByte())
        artwork.writeBytes(expected)

        try {
            val actual = context.contentResolver
                .openInputStream(AutoArtworkProvider.uriFor(context, artwork.name))
                ?.use { it.readBytes() }
            assertArrayEquals(expected, actual)
        } finally {
            artwork.delete()
        }
    }

    @Test
    fun singleTrackNowPlayingPublishesLocalCoverArt() {
        verifyNowPlayingCover { audioManager, audioUrl, coverUrl, bookId ->
            audioManager.play(
                streamUrl = audioUrl,
                bookId = bookId,
                title = "Android Auto Test Book",
                author = "Enve",
                coverUrl = coverUrl,
                mediaId = AutoMediaBrowserHelper.mediaIdForCacheKey(bookId),
            )
        }
    }

    @Test
    fun multiTrackNowPlayingPublishesLocalCoverArt() {
        verifyNowPlayingCover { audioManager, audioUrl, coverUrl, bookId ->
            audioManager.playMultiTrack(
                tracks = listOf(
                    AudioPlaybackManager.TrackInfo(audioUrl, "Part 1", 30_000),
                    AudioPlaybackManager.TrackInfo(audioUrl, "Part 2", 30_000),
                ),
                bookId = bookId,
                title = "Android Auto Test Book",
                author = "Enve",
                coverUrl = coverUrl,
                mediaId = AutoMediaBrowserHelper.mediaIdForCacheKey(bookId),
            )
        }
    }

    @Test
    fun chapterButtonsSeekToChapterBoundaries() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val audio = File(context.cacheDir, "android-auto-chapter-controls.wav")
        writeSilentWav(audio)
        val entryPoint = EntryPointAccessors.fromApplication(
            context,
            AndroidAutoDebugEntryPoint::class.java,
        )
        val audioManager = entryPoint.audioPlaybackManager()
        val chapterStore = entryPoint.chapterStore()
        val bookId = "android-auto-chapter-controls"
        chapterStore.set(
            cacheKey = bookId,
            bookId = bookId,
            chapters = listOf(
                Chapter(index = 0, title = "Chapter 1", startTime = 0, endTime = 10),
                Chapter(index = 1, title = "Chapter 2", startTime = 10, endTime = 20),
                Chapter(index = 2, title = "Chapter 3", startTime = 20, endTime = 30),
            ),
            title = "Android Auto Chapter Controls",
            author = "Enve",
            coverUrl = null,
        )
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val controllerThread = HandlerThread("android-auto-chapter-test").apply { start() }
        val controllerHandler = Handler(controllerThread.looper)
        val browser = MediaBrowser.Builder(context, token)
            .setApplicationLooper(controllerThread.looper)
            .buildAsync()
            .get(15, TimeUnit.SECONDS)
        try {
            audioManager.play(
                streamUrl = Uri.fromFile(audio).toString(),
                bookId = bookId,
                title = "Android Auto Chapter Controls",
                author = "Enve",
                coverUrl = null,
                mediaId = AutoMediaBrowserHelper.mediaIdForCacheKey(bookId),
            )
            waitUntil(controllerHandler) {
                browser.mediaItemCount == 1 && browser.duration >= 30_000L
            }
            controllerHandler.call { browser.pause() }
            audioManager.seekTo(15_000)
            waitForPosition(controllerHandler, browser, 15_000)

            val previousResult = controllerHandler.call {
                browser.sendCustomCommand(
                    SessionCommand(PlaybackAutomationContract.COMMAND_PREVIOUS_CHAPTER, Bundle.EMPTY),
                    Bundle.EMPTY,
                )
            }.get(15, TimeUnit.SECONDS)
            assertEquals(SessionResult.RESULT_SUCCESS, previousResult.resultCode)
            waitForPosition(controllerHandler, browser, 10_000)

            val nextResult = controllerHandler.call {
                browser.sendCustomCommand(
                    SessionCommand(PlaybackAutomationContract.COMMAND_NEXT_CHAPTER, Bundle.EMPTY),
                    Bundle.EMPTY,
                )
            }.get(15, TimeUnit.SECONDS)
            assertEquals(SessionResult.RESULT_SUCCESS, nextResult.resultCode)
            waitForPosition(controllerHandler, browser, 20_000)
        } finally {
            audioManager.stop()
            chapterStore.clear()
            controllerHandler.call { browser.release() }
            controllerThread.quitSafely()
            audio.delete()
        }
    }

    @Test
    fun chapterButtonsNavigateMultiFileBooks() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val audio = File(context.cacheDir, "android-auto-multi-file-chapters.wav")
        writeSilentWav(audio)
        val entryPoint = EntryPointAccessors.fromApplication(
            context,
            AndroidAutoDebugEntryPoint::class.java,
        )
        val audioManager = entryPoint.audioPlaybackManager()
        val chapterStore = entryPoint.chapterStore()
        val bookId = "android-auto-multi-file-chapters"
        chapterStore.set(
            cacheKey = bookId,
            bookId = bookId,
            chapters = listOf(
                Chapter(index = 0, title = "Part 1", startTime = 0, endTime = 30),
                Chapter(index = 1, title = "Part 2", startTime = 0, endTime = 30),
                Chapter(index = 2, title = "Part 3", startTime = 0, endTime = 30),
            ),
            title = "Android Auto Multi-file Chapters",
            author = "Enve",
            coverUrl = null,
        )
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val controllerThread = HandlerThread("android-auto-multi-file-test").apply { start() }
        val controllerHandler = Handler(controllerThread.looper)
        val browser = MediaBrowser.Builder(context, token)
            .setApplicationLooper(controllerThread.looper)
            .buildAsync()
            .get(15, TimeUnit.SECONDS)
        try {
            val audioUrl = Uri.fromFile(audio).toString()
            audioManager.playMultiTrack(
                tracks = listOf(
                    AudioPlaybackManager.TrackInfo(audioUrl, "Part 1", 30_000),
                    AudioPlaybackManager.TrackInfo(audioUrl, "Part 2", 30_000),
                    AudioPlaybackManager.TrackInfo(audioUrl, "Part 3", 30_000),
                ),
                bookId = bookId,
                title = "Android Auto Multi-file Chapters",
                author = "Enve",
                coverUrl = null,
                mediaId = AutoMediaBrowserHelper.mediaIdForCacheKey(bookId),
            )
            waitUntil(controllerHandler) { browser.mediaItemCount == 3 }
            controllerHandler.call {
                browser.pause()
                browser.seekTo(1, 5_000)
            }
            waitUntil(controllerHandler) {
                browser.currentMediaItemIndex == 1 && browser.currentPosition == 5_000L
            }

            sendChapterCommand(
                controllerHandler,
                browser,
                PlaybackAutomationContract.COMMAND_PREVIOUS_CHAPTER,
            )
            waitUntil(controllerHandler) {
                browser.currentMediaItemIndex == 1 && browser.currentPosition == 0L
            }

            sendChapterCommand(
                controllerHandler,
                browser,
                PlaybackAutomationContract.COMMAND_PREVIOUS_CHAPTER,
            )
            waitUntil(controllerHandler) {
                browser.currentMediaItemIndex == 0 && browser.currentPosition == 0L
            }

            sendChapterCommand(
                controllerHandler,
                browser,
                PlaybackAutomationContract.COMMAND_NEXT_CHAPTER,
            )
            waitUntil(controllerHandler) {
                browser.currentMediaItemIndex == 1 && browser.currentPosition == 0L
            }
        } finally {
            audioManager.stop()
            chapterStore.clear()
            controllerHandler.call { browser.release() }
            controllerThread.quitSafely()
            audio.delete()
        }
    }

    @Test
    fun playbackSpeedButtonCyclesAndPersists() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val entryPoint = EntryPointAccessors.fromApplication(
            context,
            AndroidAutoDebugEntryPoint::class.java,
        )
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val controllerThread = HandlerThread("android-auto-speed-test").apply { start() }
        val controllerHandler = Handler(controllerThread.looper)
        val browser = MediaBrowser.Builder(context, token)
            .setApplicationLooper(controllerThread.looper)
            .buildAsync()
            .get(15, TimeUnit.SECONDS)
        val originalSpeed = runBlocking {
            entryPoint.preferencesManager().playbackSpeed.first()
        }

        try {
            controllerHandler.call { browser.setPlaybackSpeed(1f) }
            val result = controllerHandler.call {
                browser.sendCustomCommand(
                    SessionCommand(
                        PlaybackAutomationContract.COMMAND_CYCLE_PLAYBACK_SPEED,
                        Bundle.EMPTY,
                    ),
                    Bundle.EMPTY,
                )
            }.get(15, TimeUnit.SECONDS)

            assertEquals(SessionResult.RESULT_SUCCESS, result.resultCode)
            waitUntil(controllerHandler) {
                browser.playbackParameters.speed == 1.25f
            }
            val persistedSpeed = runBlocking {
                entryPoint.preferencesManager().playbackSpeed.first()
            }
            assertEquals(1.25f, persistedSpeed)
        } finally {
            controllerHandler.call { browser.setPlaybackSpeed(originalSpeed) }
            runBlocking { entryPoint.preferencesManager().setPlaybackSpeed(originalSpeed) }
            controllerHandler.call { browser.release() }
            controllerThread.quitSafely()
        }
    }

    private fun verifyNowPlayingCover(
        startPlayback: (AudioPlaybackManager, String, String, String) -> Unit,
    ) {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val cover = File(context.cacheDir, "android-auto-test-cover.jpg")
        val audio = File(context.cacheDir, "android-auto-test-silence.wav")
        val bookId = "android-auto-test-${System.nanoTime()}"
        writeCover(cover)
        writeSilentWav(audio)
        val audioManager = EntryPointAccessors.fromApplication(
            context,
            AndroidAutoDebugEntryPoint::class.java,
        ).audioPlaybackManager()
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val controllerThread = HandlerThread("android-auto-artwork-test").apply { start() }
        val controllerHandler = Handler(controllerThread.looper)
        val browser = MediaBrowser.Builder(context, token)
            .setApplicationLooper(controllerThread.looper)
            .buildAsync()
            .get(15, TimeUnit.SECONDS)
        var cachedArtwork: File? = null

        try {
            startPlayback(
                audioManager,
                Uri.fromFile(audio).toString(),
                Uri.fromFile(cover).toString(),
                bookId,
            )

            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            var artworkUri: Uri? = null
            while (artworkUri == null && System.nanoTime() < deadline) {
                artworkUri = controllerHandler.call {
                    browser.currentMediaItem?.mediaMetadata?.artworkUri
                }
                if (artworkUri == null) Thread.sleep(100)
            }

            assertNotNull(artworkUri)
            assertEquals("content", artworkUri!!.scheme)
            val artwork = context.contentResolver.openInputStream(artworkUri).use {
                BitmapFactory.decodeStream(it)
            }
            assertNotNull(artwork)
            assertTrue(artwork!!.width in 1..512)
            cachedArtwork = File(
                File(context.cacheDir, AutoArtworkProvider.CACHE_DIRECTORY),
                artworkUri.lastPathSegment.orEmpty(),
            )
        } finally {
            audioManager.stop()
            controllerHandler.call { browser.release() }
            controllerThread.quitSafely()
            cover.delete()
            audio.delete()
            cachedArtwork?.delete()
        }
    }

    @Test
    fun mediaBrowserExposesCarShelves() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val chapterStore = EntryPointAccessors.fromApplication(
            context,
            AndroidAutoDebugEntryPoint::class.java,
        ).chapterStore()
        chapterStore.set(
            cacheKey = "android-auto-controls",
            bookId = "android-auto-controls",
            chapters = listOf(
                Chapter(index = 0, title = "Chapter 1", startTime = 0, endTime = 30),
                Chapter(index = 1, title = "Chapter 2", startTime = 30, endTime = 60),
            ),
            title = "Android Auto Controls",
            author = "Enve",
            coverUrl = null,
        )
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val controllerThread = HandlerThread("android-auto-browser-test").apply { start() }
        val controllerHandler = Handler(controllerThread.looper)
        val browser = MediaBrowser.Builder(context, token)
            .setApplicationLooper(controllerThread.looper)
            .buildAsync()
            .get(15, TimeUnit.SECONDS)

        try {
            val buttons = controllerHandler.call { browser.mediaButtonPreferences }
            assertEquals(4, buttons.size)
            assertEquals(
                PlaybackAutomationContract.COMMAND_PREVIOUS_CHAPTER,
                buttons[0].sessionCommand?.customAction,
            )
            assertEquals(
                listOf(CommandButton.SLOT_BACK, CommandButton.SLOT_BACK_SECONDARY),
                buttons[0].slots.asList(),
            )
            assertEquals(
                PlaybackAutomationContract.COMMAND_NEXT_CHAPTER,
                buttons[1].sessionCommand?.customAction,
            )
            assertEquals(
                listOf(CommandButton.SLOT_FORWARD, CommandButton.SLOT_FORWARD_SECONDARY),
                buttons[1].slots.asList(),
            )
            assertEquals(
                PlaybackAutomationContract.COMMAND_CYCLE_PLAYBACK_SPEED,
                buttons[2].sessionCommand?.customAction,
            )
            assertEquals(
                listOf(CommandButton.SLOT_BACK_SECONDARY, CommandButton.SLOT_OVERFLOW),
                buttons[2].slots.asList(),
            )
            assertEquals(
                PlaybackAutomationContract.COMMAND_ADD_BOOKMARK,
                buttons[3].sessionCommand?.customAction,
            )
            assertEquals(CommandButton.ICON_BOOKMARK_UNFILLED, buttons[3].icon)
            assertEquals(
                listOf(CommandButton.SLOT_FORWARD_SECONDARY, CommandButton.SLOT_OVERFLOW),
                buttons[3].slots.asList(),
            )

            val rootResult = controllerHandler.call { browser.getLibraryRoot(null) }
                .get(15, TimeUnit.SECONDS)
            val root = rootResult.value
            assertNotNull(root)
            assertEquals(AutoMediaBrowserHelper.ROOT_ID, root!!.mediaId)
            assertEquals(
                MediaConstants.EXTRAS_VALUE_CONTENT_STYLE_CATEGORY_LIST_ITEM,
                rootResult.params?.extras?.getInt(
                    MediaConstants.EXTRAS_KEY_CONTENT_STYLE_BROWSABLE,
                ),
            )
            assertEquals(
                MediaConstants.EXTRAS_VALUE_CONTENT_STYLE_GRID_ITEM,
                rootResult.params?.extras?.getInt(
                    MediaConstants.EXTRAS_KEY_CONTENT_STYLE_PLAYABLE,
                ),
            )

            val shelves = controllerHandler.call {
                browser.getChildren(root.mediaId, 0, 100, null)
            }
                .get(15, TimeUnit.SECONDS)
                .value
            assertNotNull(shelves)
            assertEquals(
                listOf(
                    AutoMediaBrowserHelper.SHELF_IN_PROGRESS,
                    AutoMediaBrowserHelper.SHELF_RECENT,
                ),
                shelves!!.map { it.mediaId },
            )
            assertEquals(
                listOf("Continue Listening", "Recently Added"),
                shelves.map { it.mediaMetadata.title.toString() },
            )
            assertEquals(
                listOf("android.resource", "android.resource"),
                shelves.map { it.mediaMetadata.artworkUri?.scheme },
            )
            assertEquals(2, shelves.map { it.mediaMetadata.artworkUri }.distinct().size)

            val recent = controllerHandler.call {
                browser.getItem(AutoMediaBrowserHelper.SHELF_RECENT)
            }
                .get(15, TimeUnit.SECONDS)
                .value
            assertNotNull(recent)
            assertEquals(AutoMediaBrowserHelper.SHELF_RECENT, recent!!.mediaId)
        } finally {
            controllerHandler.call { browser.release() }
            controllerThread.quitSafely()
            chapterStore.clear()
        }
    }

    private fun <T> Handler.call(block: () -> T): T =
        FutureTask(block).also(::post).get(15, TimeUnit.SECONDS)

    private fun sendChapterCommand(handler: Handler, browser: MediaBrowser, action: String) {
        val result = handler.call {
            browser.sendCustomCommand(SessionCommand(action, Bundle.EMPTY), Bundle.EMPTY)
        }.get(15, TimeUnit.SECONDS)
        assertEquals(SessionResult.RESULT_SUCCESS, result.resultCode)
    }

    private fun waitForPosition(handler: Handler, browser: MediaBrowser, expectedMs: Long) {
        var positionMs = -1L
        waitUntil(handler) {
            positionMs = browser.currentPosition
            kotlin.math.abs(positionMs - expectedMs) <= 250L
        }
        assertTrue(
            "Expected $expectedMs ms, was $positionMs ms",
            kotlin.math.abs(positionMs - expectedMs) <= 250L,
        )
    }

    private fun waitUntil(handler: Handler, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        var conditionMet = handler.call(condition)
        while (!conditionMet && System.nanoTime() < deadline) {
            Thread.sleep(100)
            conditionMet = handler.call(condition)
        }
        assertTrue("Condition was not met within 10 seconds", conditionMet)
    }

    private fun writeCover(file: File) {
        val bitmap = Bitmap.createBitmap(512, 512, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.rgb(45, 35, 34))
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(245, 146, 26)
            textAlign = Paint.Align.CENTER
            textSize = 132f
            typeface = android.graphics.Typeface.DEFAULT_BOLD
        }
        canvas.drawText("ENVE", 256f, 300f, paint)
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 92, it) }
        bitmap.recycle()
    }

    private fun writeSilentWav(file: File) {
        val sampleRate = 8_000
        val channelCount = 1
        val bitsPerSample = 16
        val dataSize = sampleRate * channelCount * (bitsPerSample / 8) * 30
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray())
            putInt(36 + dataSize)
            put("WAVE".toByteArray())
            put("fmt ".toByteArray())
            putInt(16)
            putShort(1)
            putShort(channelCount.toShort())
            putInt(sampleRate)
            putInt(sampleRate * channelCount * (bitsPerSample / 8))
            putShort((channelCount * (bitsPerSample / 8)).toShort())
            putShort(bitsPerSample.toShort())
            put("data".toByteArray())
            putInt(dataSize)
        }.array()
        file.outputStream().use { output ->
            output.write(header)
            output.write(ByteArray(dataSize))
        }
    }
}
