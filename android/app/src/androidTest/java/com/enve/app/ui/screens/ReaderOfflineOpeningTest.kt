package com.enve.app.ui.screens

import android.content.Context
import android.graphics.Rect
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.app.viewmodel.ReaderViewModel
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.reader.ReaderEngineKind
import dagger.hilt.android.EntryPointAccessors
import java.io.File
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import kotlin.coroutines.resume
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class ReaderOfflineOpeningTest {
    @Test
    fun cachedLocalEPUBRendersRestoresAndSavesBeforeQuickCloseInBothEngines() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val coordinator = EntryPointAccessors.fromApplication(context,
            ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use {
            await("profile runtime ready") { coordinator.activeRuntime.value != null }
        }
        val runtime = checkNotNull(coordinator.activeRuntime.value)
        val component = runtime.component
        val lastOpened = component.lastOpenedBookStore()
        val previousLastOpened = lastOpened.lastOpenedBookKey.first()
        for (engine in ReaderEngineKind.entries) {
            val id = "offline-opening-${UUID.randomUUID()}"
            val file = File(component.storageLocations().cacheDirectory, "ebooks/$id.epub")
            check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
            writeEPUB(file)
            val locator = """{"enveSharedPosition":true,"href":"chapter-2.xhtml","type":"application/xhtml+xml","locations":{"progression":0,"totalProgression":0.5,"cssSelector":"#p0"}}"""
            val book = Book(id = id, title = "Synthetic offline opening", source = BookSource.LOCAL,
                mediaType = AppMediaType.EBOOK, primaryFileType = "EPUB", epubProgress = 0.5f,
                readProgress = 0.5f, epubLocator = locator, lastReadTime = System.currentTimeMillis())
            component.bookCacheDao().upsert(listOf(book.toCachedBook()))
            fun intent(savedLocator: String?, progress: Float, lastRead: Long) = EbookReaderActivity.createIntent(
                context, id, BookSource.LOCAL, title = book.title, author = "Enve tests", bookFormat = "EPUB",
                epubLocator = savedLocator, epubProgress = progress, lastReadTime = lastRead, readerEngine = engine)
            try {
                var expectedProgress = 0f
                val firstStarted = android.os.SystemClock.elapsedRealtime()
                var scenario: ActivityScenario<EbookReaderActivity>? = ActivityScenario.launch(intent(locator, 0.5f, book.lastReadTime))
                try {
                    val opened = checkNotNull(scenario)
                    val vm = awaitReader(opened, engine, "SECOND_CHAPTER_MARKER")
                    val elapsed = android.os.SystemClock.elapsedRealtime() - firstStarted
                    Log.i("ReaderOfflineOpening", "source=LOCAL stage=visible engine=$engine opening=0 ms=$elapsed")
                    assertTrue("Cached EPUB exceeded first-open budget", elapsed < 10_000L)
                    withContext(Dispatchers.Main) { vm.seekToProgress(0.05f) }
                    await("backward navigation rendered") {
                        vm.state.value.progressPct < 30 && visibleMarker(opened, "FIRST_CHAPTER_MARKER")
                    }
                    expectedProgress = withContext(Dispatchers.Main) { vm.currentReadingProgress().toFloat() }
                    withContext(Dispatchers.Main) { vm.flushProgress() }
                    val closeStarted = android.os.SystemClock.elapsedRealtime()
                    opened.close()
                    scenario = null
                    assertTrue("Closing cached reader exceeded 2 seconds",
                        android.os.SystemClock.elapsedRealtime() - closeStarted < 2_000L)
                } finally { scenario?.close() }
                await("navigation saved after immediate close ($engine)", budgetMs = 5_000L) {
                    val saved = component.bookCacheDao().getById(id)
                    saved?.epubLocator?.contains("chapter-1.xhtml") == true &&
                        abs((saved.epubProgress ?: -1f) - expectedProgress) < 0.002f
                }
                val saved = checkNotNull(component.bookCacheDao().getById(id))
                val reopenStarted = android.os.SystemClock.elapsedRealtime()
                ActivityScenario.launch<EbookReaderActivity>(intent(saved.epubLocator,
                    checkNotNull(saved.epubProgress), saved.lastReadTime)).use { reopened ->
                    val vm = awaitReader(reopened, engine, "FIRST_CHAPTER_MARKER")
                    val elapsed = android.os.SystemClock.elapsedRealtime() - reopenStarted
                    Log.i("ReaderOfflineOpening", "source=LOCAL stage=visible engine=$engine opening=1 ms=$elapsed")
                    assertTrue("Cached EPUB reopen exceeded budget", elapsed < 10_000L)
                    assertTrue("Reopen lost the saved position",
                        abs(vm.currentReadingProgress() - expectedProgress.toDouble()) < 0.03)
                }
            } finally {
                component.bookCacheDao().deleteByCacheKeys(listOf(book.uniqueKey))
                component.database().openHelper.writableDatabase.delete(
                    "epub_bridge_checkpoints", "bookKey LIKE ?", arrayOf("%|$id|%"))
                file.delete()
                val currentLastOpened = lastOpened.lastOpenedBookKey.first()
                if (currentLastOpened == "LOCAL:$id") {
                    if (previousLastOpened == null) lastOpened.forget(currentLastOpened)
                    else lastOpened.record(previousLastOpened.substringAfter(':'), BookSource.LOCAL,
                        previousLastOpened.substringBefore(':'))
                }
            }
        }
        assertEquals(runtime.generation, coordinator.activeRuntime.value?.generation)
    }

    @Test
    fun cachedSourceNetworkPolicyIgnoresConnectivity() {
        assertTrue(!shouldUseReaderNetwork(hasOfflineSource = true, networkAvailable = true))
        assertTrue(!shouldUseReaderNetwork(hasOfflineSource = true, networkAvailable = false))
    }

    private suspend fun awaitReader(
        scenario: ActivityScenario<EbookReaderActivity>, engine: ReaderEngineKind, marker: String,
    ): ReaderViewModel {
        var reader: ReaderViewModel? = null
        await("$engine rendered the restored chapter") {
            var correctEngine = false
            scenario.onActivity { activity ->
                reader = ViewModelProvider(activity)[ReaderViewModel::class.java]
                val readium = activity.supportFragmentManager.fragments.any { it is EpubNavigatorFragment }
                val foliate = webViews(activity.window.decorView).any {
                    it.url?.contains("/assets/foliate-reader.html") == true && it.isShown
                }
                correctEngine = when (engine) {
                    ReaderEngineKind.READIUM -> readium
                    ReaderEngineKind.FOLIATE -> foliate && !readium
                }
            }
            correctEngine && checkNotNull(reader).state.value.tocEntries.isNotEmpty() && visibleMarker(scenario, marker)
        }
        return checkNotNull(reader)
    }

    private suspend fun visibleMarker(scenario: ActivityScenario<EbookReaderActivity>, marker: String): Boolean {
        val views = mutableListOf<WebView>()
        scenario.onActivity { activity ->
            views += webViews(activity.window.decorView).filter {
                it.isShown && it.getGlobalVisibleRect(Rect()) && it.width > 0 && it.height > 0
            }
        }
        for (view in views) {
            val result = withContext(Dispatchers.Main) {
                suspendCancellableCoroutine<String?> { continuation ->
                    view.evaluateJavascript(VISIBLE_TEXT_SCRIPT) { value ->
                        if (continuation.isActive) continuation.resume(value)
                    }
                }
            }
            val text = runCatching { JSONArray("[$result]").optString(0) }.getOrDefault("")
            if (text.contains(marker)) return true
        }
        return false
    }

    private fun webViews(view: View): List<WebView> = when (view) {
        is WebView -> listOf(view)
        is ViewGroup -> (0 until view.childCount).flatMap { webViews(view.getChildAt(it)) }
        else -> emptyList()
    }

    private suspend fun await(description: String, budgetMs: Long = 10_000L, condition: suspend () -> Boolean) {
        val deadline = android.os.SystemClock.elapsedRealtime() + budgetMs
        while (!condition()) {
            check(android.os.SystemClock.elapsedRealtime() < deadline) { description }
            delay(50)
        }
    }

    private fun writeEPUB(file: File) {
        val entries = linkedMapOf(
            "mimetype" to "application/epub+zip",
            "META-INF/container.xml" to """<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""",
            "package.opf" to """<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">offline-fixture</dc:identifier><dc:title>Offline fixture</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-29T00:00:00Z</meta></metadata><manifest><item id="one" href="chapter-1.xhtml" media-type="application/xhtml+xml"/><item id="two" href="chapter-2.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>""",
            "nav.xhtml" to """<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter-1.xhtml">One</a></li><li><a href="chapter-2.xhtml">Two</a></li></ol></nav></body></html>""",
            "chapter-1.xhtml" to chapter("FIRST_CHAPTER_MARKER"),
            "chapter-2.xhtml" to chapter("SECOND_CHAPTER_MARKER"),
        )
        ZipOutputStream(file.outputStream()).use { zip ->
            for ((name, text) in entries) {
                val bytes = text.toByteArray(Charsets.UTF_8)
                val entry = ZipEntry(name)
                if (name == "mimetype") {
                    entry.method = ZipEntry.STORED
                    entry.size = bytes.size.toLong()
                    entry.compressedSize = bytes.size.toLong()
                    entry.crc = java.util.zip.CRC32().apply { update(bytes) }.value
                }
                zip.putNextEntry(entry)
                zip.write(bytes)
                zip.closeEntry()
            }
        }
    }

    private fun chapter(marker: String): String = "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>$marker</title></head><body>" +
        (0 until 80).joinToString("") { "<p id='p$it'>$marker paragraph $it. Synthetic reader opening and restoration fixture.</p>" } +
        "</body></html>"

    private companion object {
        val VISIBLE_TEXT_SCRIPT = """
            (() => {
                const visible = (r, w) => r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < w.innerHeight && r.left < w.innerWidth;
                const foliate = document.querySelector('foliate-view');
                const docs = foliate?.renderer?.getContents?.().map(item => item.doc) ?? [document];
                return docs.flatMap(doc => Array.from(doc.querySelectorAll('p'))
                    .filter(p => visible(p.getBoundingClientRect(), doc.defaultView))
                    .map(p => p.textContent)).join('\n');
            })()
        """.trimIndent()
    }
}
