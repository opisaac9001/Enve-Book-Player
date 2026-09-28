package com.enve.app.widgets

import android.content.Context
import android.content.Intent
import android.appwidget.AppWidgetManager
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.enve.app.MainActivity
import com.enve.app.ui.screens.ComicReaderActivity
import com.enve.app.ui.screens.EbookReaderActivity
import com.enve.app.ui.screens.PdfReaderActivity
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.local.EpubCoverExtractor
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WidgetRoutingTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val book = Book(
        id = "widget-test", title = "Widget test", source = BookSource.LOCAL,
        mediaType = AppMediaType.EBOOK, primaryFileType = "EPUB",
        connectionId = "test-library", epubLocator = "saved-locator", epubProgress = 0.42f,
        lastReadTime = 1234L,
    )

    @Test
    fun widgetReaderBackReturnsToHearth() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        context.startActivity(context.widgetReaderIntentFor(book.copy(primaryFileType = "PDF"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val deadline = android.os.SystemClock.uptimeMillis() + 15_000
        var readerResumed = false
        while (!readerResumed && android.os.SystemClock.uptimeMillis() < deadline) {
            instrumentation.runOnMainSync {
                readerResumed = ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(Stage.RESUMED).any { it is PdfReaderActivity }
            }
            if (!readerResumed) android.os.SystemClock.sleep(100)
        }
        assertTrue("Widget must open the reader", readerResumed)
        instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        val backDeadline = android.os.SystemClock.uptimeMillis() + 15_000
        var hearthResumed = false
        while (!hearthResumed && android.os.SystemClock.uptimeMillis() < backDeadline) {
            instrumentation.runOnMainSync {
                hearthResumed = ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(Stage.RESUMED).any { it is MainActivity }
            }
            if (!hearthResumed) android.os.SystemClock.sleep(100)
        }
        assertTrue("Back must return to Hearth", hearthResumed)
    }

    @Test
    fun widgetLaunchPreservesReaderDestinationAndPosition() {
        for (format in listOf("EPUB", "PDF", "CBZ", "CBR", "CBX")) {
            val selected = book.copy(primaryFileType = format)
            val reader = context.readerIntentFor(selected)
            val widget = context.widgetReaderIntentFor(selected)
            assertEquals(WidgetReaderActivity::class.java.name, widget.component?.className)
            assertEquals(reader.component?.className,
                widget.getStringExtra(WidgetReaderActivity.EXTRA_READER_CLASS))
            for (key in requireNotNull(reader.extras).keySet()) {
                @Suppress("DEPRECATION")
                assertEquals(reader.extras?.get(key), widget.extras?.get(key))
            }
        }
    }

    @Test
    fun onlyOneWidgetIsRegistered() {
        val receivers = context.packageManager.queryBroadcastReceivers(
            Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).setPackage(context.packageName), 0,
        )
        assertEquals(listOf(BookPlayerWidgetReceiver::class.java.name), receivers.map { it.activityInfo.name })
    }

    @Test
    fun localEpubClassificationUsesDeclaredMediaOverlaysNotJustAudioFiles() {
        val file = File.createTempFile("widget-epub-", ".epub", context.cacheDir)
        try {
            for (overlay in listOf(false, true)) {
                ZipOutputStream(file.outputStream()).use { zip ->
                    zip.putNextEntry(ZipEntry("META-INF/container.xml"))
                    zip.write("<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>".toByteArray())
                    zip.closeEntry()
                    zip.putNextEntry(ZipEntry("content.opf"))
                    val reference = if (overlay) "media-overlay=\"narration\"" else ""
                    zip.write(("<package><manifest>" +
                        "<item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\" $reference/>" +
                        "<item id=\"narration\" href=\"chapter.smil\" media-type=\"application/smil+xml\"/>" +
                        "<item id=\"audio\" href=\"audio.mp3\" media-type=\"audio/mpeg\"/>" +
                        "</manifest></package>").toByteArray())
                    zip.closeEntry()
                }
                val metadata = requireNotNull(EpubCoverExtractor.extractMetadata(context, Uri.fromFile(file)))
                assertEquals(overlay, metadata.readAlongAvailable)
            }
            assertFalse(book.supportsListening())
        } finally {
            file.delete()
        }
    }

    @Test
    fun ebookPreservesIdentityAndReadingPosition() {
        val intent = context.readerIntentFor(book)
        assertEquals(EbookReaderActivity::class.java.name, intent.component?.className)
        assertEquals("EPUB", intent.getStringExtra("bookFormat"))
        assertEquals(book.id, intent.getStringExtra("bookId"))
        assertEquals(book.connectionId, intent.getStringExtra("connectionId"))
        assertEquals(book.epubLocator, intent.getStringExtra("epubLocator"))
        assertEquals(0.42f, intent.getFloatExtra("epubProgress", 0f))
        assertEquals(1234L, intent.getLongExtra("lastReadTime", 0L))
    }

    @Test
    fun localAndStorytellerReadAlongUseReadAloudMode() {
        for (source in listOf(BookSource.LOCAL, BookSource.STORYTELLER)) {
            val intent = context.readerIntentFor(book.copy(source = source, readAlongAvailable = true))
            assertEquals(EbookReaderActivity::class.java.name, intent.component?.className)
            assertEquals("READALOUD", intent.getStringExtra("bookFormat"))
        }
    }

    @Test
    fun bundledEbookDoesNotOpenAudioFileAsText() {
        val intent = context.readerIntentFor(book.copy(
            mediaType = AppMediaType.AUDIOBOOK, hasEbook = true, primaryFileType = "M4B",
        ))
        assertEquals("EPUB", intent.getStringExtra("bookFormat"))
    }

    @Test
    fun pdfAndComicsUseTheirOwnReaders() {
        assertEquals(PdfReaderActivity::class.java.name,
            context.readerIntentFor(book.copy(primaryFileType = "PDF")).component?.className)
        for (format in listOf("CBZ", "CBR", "CBX")) {
            assertEquals(ComicReaderActivity::class.java.name,
                context.readerIntentFor(book.copy(primaryFileType = format)).component?.className)
        }
    }

    @Test
    fun activeWidgetObservesPlaybackChanges() = runBlocking {
        val name = "widget-snapshot-test"
        val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        try {
            withTimeout(5_000) {
                val ready = CompletableDeferred<Unit>()
                val values = async {
                    widgetSnapshots(context, name) { prefs.getBoolean("playing", false) }
                        .onEach { ready.complete(Unit) }.take(2).toList()
                }
                ready.await()
                prefs.edit().putBoolean("playing", true).commit()
                assertEquals(listOf(false, true), values.await())
            }
        } finally {
            prefs.edit().clear().commit()
        }
    }
}
