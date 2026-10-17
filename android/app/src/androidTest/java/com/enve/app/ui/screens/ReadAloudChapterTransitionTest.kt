package com.enve.app.ui.screens

import android.content.Context
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.MainActivity
import com.enve.app.readium.MediaOverlayEngine
import com.enve.app.readium.ReadAloudPlaybackCoordinator
import com.enve.app.readium.ReadAloudPlaybackSession
import com.enve.app.readium.ReadiumManager
import com.enve.app.storyalign.align.AlignedChapter
import com.enve.app.storyalign.align.AlignedSentence
import com.enve.app.storyalign.align.AudioFile
import com.enve.app.storyalign.align.SentenceRange
import com.enve.app.storyalign.epub.EpubParser
import com.enve.app.storyalign.epub.EpubZip
import com.enve.app.storyalign.export.ReadAloudEpubBuilder
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.readium.r2.shared.util.getOrElse

@RunWith(AndroidJUnit4::class)
class ReadAloudChapterTransitionTest {
    @Test
    fun naturalChapterEndDoesNotDoubleAdvanceWhileReaderReconcilesPlayback() = verifyPlayback(false)

    @Test
    fun chaptersCanShareAudioFilesAndSpanMultipleFiles() = verifyPlayback(true)

    @Test
    fun sharedAudioPlaybackResumesWithoutRepeatingOrSkippingAChapter() = verifyPlayback(true, pauseAtBoundary = true)

    @Test
    fun storyAlignChaptersWithMatchingFileNamesPlayInOrder() = verifyPlayback(false, generated = true)

    private fun verifyPlayback(mixed: Boolean, pauseAtBoundary: Boolean = false, generated: Boolean = false) = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        ActivityScenario.launch(MainActivity::class.java).close()
        val directory = File(context.cacheDir, "chapter-transition-${UUID.randomUUID()}").apply { mkdirs() }
        val file = File(directory, "narrated.epub")
        writeBook(file, mixed, generated)
        val manager = ReadiumManager(context)
        val asset = manager.assetRetriever.retrieve(file).getOrElse { error("Fixture asset could not open") }
        val publication = manager.publicationOpener.open(asset, allowUserInteraction = false)
            .getOrElse { error("Fixture publication could not open") }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val playback = ReadAloudPlaybackCoordinator(context, scope)
        val session = ReadAloudPlaybackSession(UUID.randomUUID().toString(), "chapter-fixture", "Chapter fixture", null)
        val engine = MediaOverlayEngine(context, publication, scope, file, playback, session)
        val visited = CopyOnWriteArrayList<String>()
        val visitedClips = CopyOnWriteArrayList<String>()
        val complete = CompletableDeferred<Unit>()
        val failure = CompletableDeferred<String>()
        engine.onClipChanged = { clip, _ ->
            if (visited.lastOrNull() != clip.textHref) visited.add(clip.textHref)
            val identity = "${clip.textHref.substringAfterLast('/')}|${clip.audioHref.substringAfterLast('/')}|${clip.clipBeginMs}"
            if (visitedClips.lastOrNull() != identity) visitedClips.add(identity)
        }
        engine.onPlaybackCompleted = { complete.complete(Unit) }
        engine.onPlaybackFailed = { failure.complete(it) }
        try {
            withContext(Dispatchers.Main) {
                playback.connect()
                engine.play(if (generated) "section-0/chapter.xhtml" else "chapter-0.xhtml")
            }
            var paused = false
            withTimeout(30000) {
                while (!complete.isCompleted) {
                    check(!failure.isCompleted) { failure.await() }
                    withContext(Dispatchers.Main) { engine.reconcilePlaybackPosition() }
                    if (pauseAtBoundary && !paused && visited.lastOrNull()?.endsWith("chapter-1.xhtml") == true) {
                        paused = true
                        withContext(Dispatchers.Main) { engine.pause() }
                        val clipsBeforePause = visitedClips.toList()
                        delay(300)
                        assertEquals(clipsBeforePause, visitedClips.toList())
                        withContext(Dispatchers.Main) { engine.resume() }
                    }
                    delay(20)
                }
            }
            assertTrue(!pauseAtBoundary || paused)
            if (generated) {
                assertEquals((0..3).map(Int::toString), visited.map { it.substringAfterLast("section-").substringBefore('/') })
            } else {
                assertEquals((0..3).map { "chapter-$it.xhtml" }, visited.map { it.substringAfterLast('/') })
            }
            assertEquals(layout(mixed).map { (chapter, audio, begin) ->
                "${if (generated) "chapter.xhtml" else "chapter-$chapter.xhtml"}|chapter-$audio.wav|${begin * 1000L}"
            }, visitedClips.toList())
        } finally {
            withContext(Dispatchers.Main) { engine.release() }
            playback.stopActiveAndAwait()
            scope.cancel()
            publication.close()
            directory.deleteRecursively()
        }
    }

    private fun layout(mixed: Boolean) = if (mixed) listOf(
        Triple(0, 0, 0), Triple(0, 1, 0), Triple(1, 1, 1),
        Triple(2, 1, 2), Triple(2, 2, 0), Triple(3, 2, 1),
    ) else (0..3).map { Triple(it, it, 0) }

    private fun writeBook(file: File, mixed: Boolean, generated: Boolean) {
        fun chapterHref(index: Int) = if (generated) "section-$index/chapter.xhtml" else "chapter-$index.xhtml"
        val layout = layout(mixed)
        val pcmSize = if (mixed) 48000 else 32000
        val wav = ByteBuffer.allocate(44 + pcmSize).order(ByteOrder.LITTLE_ENDIAN)
            .put("RIFF".toByteArray()).putInt(36 + pcmSize).put("WAVEfmt ".toByteArray())
            .putInt(16).putShort(1).putShort(1).putInt(8000).putInt(16000)
            .putShort(2).putShort(16).put("data".toByteArray()).putInt(pcmSize).array()
        ZipOutputStream(file.outputStream()).use { zip ->
            fun entry(name: String, bytes: ByteArray) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(bytes)
                zip.closeEntry()
            }
            fun text(name: String, value: String) = entry(name, value.toByteArray())
            text("mimetype", "application/epub+zip")
            text("META-INF/container.xml", """<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""")
            val manifest = (0..3).joinToString("") { """<item id="c$it" href="${chapterHref(it)}" media-type="application/xhtml+xml" media-overlay="s$it"/><item id="s$it" href="chapter-$it.smil" media-type="application/smil+xml"/><item id="a$it" href="chapter-$it.wav" media-type="audio/wav"/>""" }
            val spine = (0..3).joinToString("") { """<itemref idref="c$it"/>""" }
            text("book.opf", """<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">chapter-fixture</dc:identifier><dc:title>Chapter transition fixture</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-11T00:00:00Z</meta></metadata><manifest>$manifest</manifest><spine>$spine</spine></package>""")
            for (index in 0..3) {
                text(chapterHref(index), """<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter $index</title></head><body><p id="text">Chapter $index narration.</p></body></html>""")
                val clips = layout.filter { it.first == index }.joinToString("") { (_, audio, begin) ->
                    val end = begin + if (mixed) 1 else 2
                    """<par><text src="chapter-$index.xhtml#text"/><audio src="chapter-$audio.wav" clipBegin="${begin}s" clipEnd="${end}s"/></par>"""
                }
                text("chapter-$index.smil", """<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><seq>$clips</seq></body></smil>""")
                entry("chapter-$index.wav", wav)
            }
        }
        if (generated) {
            val original = file.inputStream().use(EpubZip::from)
            val document = EpubParser.parse(original)
            val chapters = document.spineOrderedManifest.mapIndexed { index, item ->
                val audio = AudioFile(index, 0.0, 2.0, "chapter-$index.wav")
                AlignedChapter(item, alignedSentences = listOf(AlignedSentence("Chapter $index narration.", 0,
                    SentenceRange(0, 0.0, 2.0, audio, emptyList()))))
            }
            file.writeBytes(ReadAloudEpubBuilder.build(original, document, chapters,
                (0..3).map { ReadAloudEpubBuilder.AudioClipFile("chapter-$it.wav", wav) }, "2026-10-12T00:00:00Z"))
        }
    }
}
