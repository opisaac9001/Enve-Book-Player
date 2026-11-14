package com.enve.app.storyalign

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.core.app.ActivityScenario
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.app.ui.screens.EbookReaderActivity
import com.enve.app.viewmodel.ReaderUiState
import com.enve.app.viewmodel.ReaderViewModel
import com.enve.app.playback.AutoMediaBrowserHelper
import com.enve.core.data.local.toCachedBook
import com.enve.core.reader.ReaderEngineKind
import dagger.hilt.android.EntryPointAccessors
import com.enve.app.playback.PlaybackState
import com.enve.app.storyalign.audio.AudioWindowDecoder
import com.enve.app.storyalign.ctc.QuartzNetModelStore
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.ConnectionScope
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.Rule
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PassageAlignmentLiveTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test fun readerFollowsTheLinkedAudiobookAndKeepsTransportControlsUsable() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val profiles = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use {
            withTimeout(30_000) { while (profiles.activeRuntime.value == null || profiles.state.value.locked || profiles.state.value.switching) delay(50) }
        }
        val component = checkNotNull(profiles.activeRuntime.value).component
        val directory = File(context.cacheDir, "reader-live-${UUID.randomUUID()}").apply { mkdirs() }
        val epub = File(directory, "original.epub")
        val audio = File(directory, "narration.wav")
        writeEpub(epub)
        synthesize(context, audio)
        val ebook = Book(id = android.net.Uri.fromFile(epub).toString(), title = "Harbor fixture", source = BookSource.LOCAL, mediaType = AppMediaType.EBOOK, language = "English", primaryFileType = "EPUB", hasEbook = true)
        val audiobook = ebook.copy(id = android.net.Uri.fromFile(audio).toString(), mediaType = AppMediaType.AUDIOBOOK, primaryFileType = "WAV", hasEbook = false, hasAudio = true)
        component.bookCacheDao().upsert(listOf(ebook.toCachedBook(), audiobook.toCachedBook()))
        component.bookLinks().link(ebook, audiobook)
        try {
            withContext(Dispatchers.Main) {
                component.audioPlayback().connect()
                component.audioPlayback().play(audio.toURI().toString(), audiobook.id, audiobook.title, null, null,
                    startPositionMs = 45_000, mediaId = AutoMediaBrowserHelper.mediaIdForCacheKey(audiobook.uniqueKey))
            }
            withTimeout(20_000) { component.audioPlayback().state.first { it.isReady && it.isPlaying } }
            withContext(Dispatchers.Main) { component.audioPlayback().togglePlayPause() }
            val intent = EbookReaderActivity.createIntent(context, ebook.id, BookSource.LOCAL, title = ebook.title,
                author = "Fixture", bookFormat = "EPUB", epubLocator = null, epubProgress = 0f, readerEngine = ReaderEngineKind.READIUM)
            ActivityScenario.launch<EbookReaderActivity>(intent).use { scenario ->
                lateinit var model: ReaderViewModel
                scenario.onActivity { activity -> model = ViewModelProvider(activity)[ReaderViewModel::class.java] }
                fun awaitReader(description: String, condition: (ReaderUiState) -> Boolean) {
                    try { compose.waitUntil(30_000) { condition(model.state.value) } }
                    catch (error: androidx.compose.ui.test.ComposeTimeoutException) {
                        val state = model.state.value
                        throw AssertionError("$description: progress=${state.progressPct}, following=${state.liveReadAlongFollowing}, status=${state.liveReadAlongStatus}", error)
                    }
                }
                awaitReader("Live link available") { it.liveReadAlongAvailable }
                withContext(Dispatchers.Main) { if (!model.state.value.showChrome) model.toggleChrome() }
                compose.onNodeWithContentDescription("Read Aloud").performClick()
                awaitReader("Narrated passage found") { it.liveReadAlongStatus == "Following audiobook" }
                awaitReader("Reader reaches later passage") { it.progressPct > 0 }
                assertTrue(model.state.value.liveReadAlongActive)
                compose.waitForIdle()
                val screenshots = File(context.getExternalFilesDir(null), "parity-verification").apply { mkdirs() }
                InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot().let { bitmap ->
                    File(screenshots, "linked-read-along.png").outputStream().use {
                        bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                    }
                    bitmap.recycle()
                }
                withContext(Dispatchers.Main) { model.seekToProgress(0f) }
                awaitReader("Browsing suspends following") { !it.liveReadAlongFollowing && it.progressPct == 0 }
                withContext(Dispatchers.Main) { if (!model.state.value.showChrome) model.toggleChrome() }
                compose.onNodeWithText("Return to audiobook").performClick()
                awaitReader("Return reaches narrated passage") { it.liveReadAlongFollowing && it.progressPct > 0 }
                withContext(Dispatchers.Main) { if (!model.state.value.showChrome) model.toggleChrome() }
                compose.onNodeWithContentDescription("Play audiobook").performClick()
                awaitReader("Audiobook plays") { it.liveReadAlongPlaying }
                withContext(Dispatchers.Main) { if (!model.state.value.showChrome) model.toggleChrome() }
                compose.onNodeWithContentDescription("Pause audiobook").performClick()
                awaitReader("Audiobook pauses") { !it.liveReadAlongPlaying }
                assertTrue(model.state.value.liveReadAlongFollowing)
                withContext(Dispatchers.Main) { model.seekToProgress(0f) }
                awaitReader("First page is ready for handoff") { !it.liveReadAlongFollowing && it.progressPct == 0 }
                withContext(Dispatchers.Main) { if (!model.state.value.showChrome) model.toggleChrome() }
                compose.onNodeWithText("Listen from this page").performClick()
                awaitReader("Reading position becomes the listening position") {
                    it.liveReadAlongFollowing && it.liveReadAlongPlaying && component.audioPlayback().state.value.currentPositionMs < 12_000
                }
                withContext(Dispatchers.Main) { if (!model.state.value.showChrome) model.toggleChrome() }
                compose.onNodeWithContentDescription("Pause audiobook").performClick()
                awaitReader("Audiobook pauses after the handoff") { !it.liveReadAlongPlaying }
                withContext(Dispatchers.Main) { if (!model.state.value.showChrome) model.toggleChrome() }
                compose.onNodeWithContentDescription("Stop following audiobook").performClick()
                awaitReader("Following stops") { !it.liveReadAlongActive }
                assertTrue(!component.audioPlayback().state.value.isPlaying)
            }
        } finally {
            component.playback().stop()
            component.bookLinks().unlink(ebook)
            component.bookCacheDao().deleteByCacheKeys(listOf(ebook.uniqueKey, audiobook.uniqueKey))
            directory.deleteRecursively()
        }
    }
    @Test fun realNarrationAlignsFromAStreamAndRestoresItsPreparedPassages() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val id = UUID.randomUUID().toString()
        val locations = ProfileStorageLocations.forProfile(context, id)
        val directory = File(context.cacheDir, "live-alignment-$id").apply { mkdirs() }
        val epub = File(directory, "original.epub")
        val audio = File(directory, "narration.wav")
        try {
            writeEpub(epub)
            synthesize(context, audio)
            val duration = android.media.MediaMetadataRetriever().let { reader ->
                try {
                    reader.setDataSource(audio.path)
                    checkNotNull(reader.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)).toLong()
                } finally { reader.release() }
            }
            val client = OkHttpClient.Builder().addInterceptor { chain ->
                chain.proceed(chain.request().newBuilder()
                    .header("X-Fixture-Connection", ConnectionScope.getConnectionId().orEmpty()).build())
            }.build()
            val local = withContext(Dispatchers.IO) { AudioWindowDecoder(context, client).decode(audio.path, null, 10.0, 1.0) }
            assertTrue(local.size > 512)
            AudioWindowDecoderTest.Fixture(audio.readBytes()).use { server ->
                val service = PassageAlignmentService(context, locations, QuartzNetModelStore(context), AudioWindowDecoder(context, client), client)
                val ebook = Book(id = "ebook", title = "Harbor fixture", source = BookSource.LOCAL, mediaType = AppMediaType.EBOOK, connectionId = "fixture-connection", language = "eng")
                val audiobook = ebook.copy(id = "audio", mediaType = AppMediaType.AUDIOBOOK)
                val tracks = listOf(AudioTrack(index = 0, fileName = "narration.wav", durationMs = duration, contentUrl = server.url))
                fun start(found: CompletableDeferred<PassageMapping>) = launch(Dispatchers.Main) {
                    service.follow(ebook, audiobook, epub, tracks,
                        playback = { PlaybackState(currentPositionMs = 12_000, playbackSpeed = 1f) },
                        isForeground = { true },
                        onUpdate = { state -> state.mapping?.let { found.complete(it) } },
                    )
                }
                val initial = CompletableDeferred<PassageMapping>()
                val firstWorker = start(initial)
                val first = withTimeout(180_000) { initial.await() }
                val saved = File(locations.filesDirectory, "passage-alignment")
                withTimeout(5_000) { while (saved.listFiles().orEmpty().none { it.extension == "json" }) delay(20) }
                val next = CompletableDeferred<PassageMapping>()
                val secondWorker = start(next)
                val restored = try { withTimeout(30_000) { next.await() } } finally {
                    firstWorker.cancelAndJoin()
                    secondWorker.cancelAndJoin()
                }
                assertTrue(firstWorker.isCancelled)
                assertTrue(first.start <= 12 && first.end > 12)
                assertTrue("Root-package chapter paths must stay relative to the EPUB", !first.href.startsWith("/"))
                assertTrue(TEXT.contains(first.text))
                assertTrue(restored.sentence == first.sentence)
                assertTrue(restored.start == first.start && restored.end == first.end)
                assertTrue(File(locations.filesDirectory, "passage-alignment").listFiles().orEmpty().any { it.extension == "json" })
            }
        } finally {
            directory.deleteRecursively()
            locations.filesDirectory.deleteRecursively()
            locations.cacheDirectory.deleteRecursively()
        }
    }

    private suspend fun synthesize(context: Context, destination: File) {
        val initialized = CompletableDeferred<Int>()
        val tts = withContext(Dispatchers.Main) { TextToSpeech(context) { initialized.complete(it) } }
        try {
            assumeTrue(withTimeout(20_000) { initialized.await() } == TextToSpeech.SUCCESS)
            val finished = CompletableDeferred<Unit>()
            tts.setLanguage(Locale.US)
            tts.voices?.firstOrNull { it.locale.language == "en" && !it.isNetworkConnectionRequired }?.let(tts::setVoice)
            tts.setSpeechRate(0.85f)
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) = Unit
                override fun onDone(utteranceId: String?) { finished.complete(Unit) }
                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) { finished.completeExceptionally(IllegalStateException("Fixture speech synthesis failed")) }
            })
            check(tts.synthesizeToFile(TEXT, Bundle(), destination, "fixture") == TextToSpeech.SUCCESS)
            withTimeout(60_000) { finished.await() }
        } finally { tts.shutdown() }
    }

    private fun writeEpub(file: File) {
        ZipOutputStream(file.outputStream()).use { archive ->
            fun entry(path: String, text: String) {
                archive.putNextEntry(ZipEntry(path)); archive.write(text.toByteArray()); archive.closeEntry()
            }
            entry("mimetype", "application/epub+zip")
            entry("META-INF/container.xml", """<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""")
            val chapters = TEXT.split(". ").map { it.trimEnd('.') + "." }
            val manifest = chapters.indices.joinToString("") { "<item id=\"c$it\" href=\"chapter-$it.xhtml\" media-type=\"application/xhtml+xml\"/>" }
            val spine = chapters.indices.joinToString("") { "<itemref idref=\"c$it\"/>" }
            entry("book.opf", """<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">harbor</dc:identifier><dc:title>Harbor</dc:title><dc:language>en</dc:language></metadata><manifest>$manifest</manifest><spine>$spine</spine></package>""")
            chapters.forEachIndexed { index, text ->
                entry("chapter-$index.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Harbor ${index + 1}</title></head><body><p>$text</p></body></html>""")
            }
        }
    }

    private companion object {
        const val TEXT = "At sunrise the harbor was quiet. The lantern keeper opened the wooden gate. Beyond the pier the water shone like silver. A small boat waited beside the old stone steps. The captain carried a basket of fresh bread. He called to the children watching from the bridge. They waved their bright scarves in the morning breeze. Soon the market would open near the clock tower. Everyone in the village knew the road to the sea. The baker had already lit the fire in his oven. Warm light spread across the windows of the narrow street. A black cat slept beneath the wooden bench. Far away a bell rang from the hillside church. The lantern keeper checked the glass and polished the brass. He had watched these waters for many years. Each evening he climbed the winding stairs to light the lamp. Sailors followed its steady glow through the darkness. Today the sky was clear and the wind was gentle. He placed his tools on the table and smiled. There would be time for a walk before the next tide."
    }
}
