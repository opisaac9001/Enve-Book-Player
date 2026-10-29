package com.enve.app.ui.screens

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.MainActivity
import com.enve.app.R
import com.enve.app.data.reader.ReaderPreferences
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.app.viewmodel.ReaderViewModel
import com.enve.app.viewmodel.TocEntry
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.reader.ReaderEngineKind
import dagger.hilt.android.EntryPointAccessors
import java.io.ByteArrayOutputStream
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
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import kotlin.coroutines.resume
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class ReaderRenderingQualityTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun jpegOrientationMatchesTheInlineImage() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val file = File.createTempFile("reader-orientation", ".jpg", context.cacheDir)
        try {
            val image = Bitmap.createBitmap(200, 100, Bitmap.Config.ARGB_8888)
            file.outputStream().use { image.compress(Bitmap.CompressFormat.JPEG, 90, it) }
            image.recycle()
            android.media.ExifInterface(file.path).apply {
                setAttribute(android.media.ExifInterface.TAG_ORIENTATION, "6")
                saveAttributes()
            }
            val decoded = checkNotNull(com.enve.app.ui.screens.reader.ReaderIllustrationLoader.decode(file.readBytes()))
            assertEquals(100, decoded.width)
            assertEquals(200, decoded.height)
            decoded.recycle()
        } finally { file.delete() }
    }

    @Test
    fun oversizedContentIllustrationsAndPinchWorkInBothEngines() = runBlocking {
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
            val id = "render-quality-${UUID.randomUUID()}"
            val file = File(component.storageLocations().cacheDirectory, "ebooks/$id.epub")
            check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
            writeEPUB(file)
            val book = Book(id = id, title = "Synthetic rendering fixture", source = BookSource.LOCAL,
                mediaType = AppMediaType.EBOOK, primaryFileType = "EPUB")
            component.bookCacheDao().upsert(listOf(book.toCachedBook()))
            var original: ReaderPreferences? = null
            var vm: ReaderViewModel? = null
            val scenario = ActivityScenario.launch<EbookReaderActivity>(EbookReaderActivity.createIntent(
                context, id, BookSource.LOCAL, title = book.title, author = "Enve tests", bookFormat = "EPUB",
                epubLocator = null, epubProgress = 0f, readerEngine = engine))
            try {
                await("requested reader engine ready") {
                    var matched = false
                    scenario.onActivity { activity ->
                        vm = ViewModelProvider(activity)[ReaderViewModel::class.java]
                        val readium = activity.supportFragmentManager.fragments.any { it is EpubNavigatorFragment }
                        val foliate = webViews(activity.window.decorView).any {
                            it.isShown && it.url?.contains("/assets/foliate-reader.html") == true
                        }
                        matched = if (engine == ReaderEngineKind.READIUM) readium else foliate && !readium
                    }
                    matched && checkNotNull(vm).state.value.tocEntries.isNotEmpty()
                }
                val reader = checkNotNull(vm)
                val baseline = reader.state.value.prefs
                original = baseline
                withContext(Dispatchers.Main) {
                    reader.updatePreferences(baseline.copy(publisherStyles = true, fontSize = 1f, scroll = false))
                }
                var metrics: JSONObject? = null
                await("oversized DOM content fitted") {
                    metrics = dom(scenario, FIT_METRICS)?.second
                    val m = metrics ?: return@await false
                    m.optDouble("wideMax", 0.0) > 20 && m.optDouble("preMax", 0.0) > 20 &&
                        m.optDouble("wideMax", Double.POSITIVE_INFINITY) <= m.optDouble("available", 0.0) + 2 &&
                        m.optDouble("preMax", Double.POSITIVE_INFINITY) <= m.optDouble("preAvailable", 0.0) + 2
                }
                val fitted = checkNotNull(metrics)
                assertTrue(fitted.getDouble("wideMax") > 20)
                assertTrue(fitted.getDouble("preMax") > 20)
                assertTrue(abs(fitted.getDouble("smallWidth") - 128.0) < 2.0)
                assertEquals("auto", fitted.getString("smallLayout"))
                assertTrue(!fitted.getBoolean("smallHasFitAttribute"))
                assertEquals("7px", fitted.getString("smallInlineSpacing"))

                withContext(Dispatchers.Main) {
                    reader.navigateTo(TocEntry("image-fixture", "Illustration", "image.xhtml", 0))
                }
                var image: Pair<WebView, JSONObject>? = null
                await("raster image visible") {
                    image = dom(scenario, imageRectScript())
                    image != null
                }
                await("illustration location observed") { reader.state.value.currentTocEntryId?.contains("image.xhtml") == true }
                delay(400)
                val beforeViewer = withContext(Dispatchers.Main) { reader.currentReadingProgress() }
                val beforeSection = reader.state.value.currentTocEntryId
                val imageTarget = checkNotNull(image)
                tap(scenario, imageTarget)
                compose.waitUntil(timeoutMillis = 5_000L) {
                    compose.onAllNodesWithText("Synthetic figure caption").fetchSemanticsNodes().isNotEmpty()
                }
                compose.onNodeWithText("Synthetic figure caption").assertIsDisplayed()
                compose.onNodeWithContentDescription("Synthetic raster diagram").assertIsDisplayed()
                compose.onNodeWithContentDescription(context.getString(R.string.close_illustration)).performClick()
                await("reader restored after illustration dismissal") { dom(scenario, imageRectScript()) != null }
                assertTrue("Viewer moved from $beforeViewer to ${reader.currentReadingProgress()}", abs(withContext(Dispatchers.Main) { reader.currentReadingProgress() } - beforeViewer) < 0.002)
                assertEquals(beforeSection, reader.state.value.currentTocEntryId)

                val text = checkNotNull(dom(scenario, textRectScript()))
                val priorFont = text.second.getDouble("fontSize")
                val priorScale = reader.state.value.prefs.fontSize
                pinch(scenario, text)
                await("pinch changed actual rendered text") {
                    val changed = dom(scenario, textRectScript())?.second ?: return@await false
                    reader.state.value.prefs.fontSize > priorScale && changed.getDouble("fontSize") > priorFont * 1.1
                }
                assertEquals(beforeSection, reader.state.value.currentTocEntryId)
            } finally {
                val preferences = original
                val reader = vm
                if (preferences != null && reader != null) {
                    withContext(Dispatchers.Main) { reader.updatePreferences(preferences) }
                    delay(300)
                }
                scenario.close()
                component.bookCacheDao().deleteByCacheKeys(listOf(book.uniqueKey))
                component.database().openHelper.writableDatabase.delete(
                    "epub_bridge_checkpoints", "bookKey LIKE ?", arrayOf("%|$id|%"))
                file.delete()
                val current = lastOpened.lastOpenedBookKey.first()
                if (current == "LOCAL:$id") {
                    if (previousLastOpened == null) lastOpened.forget(current)
                    else lastOpened.record(previousLastOpened.substringAfter(':'), BookSource.LOCAL,
                        previousLastOpened.substringBefore(':'))
                }
            }
        }
    }

    private suspend fun dom(scenario: ActivityScenario<EbookReaderActivity>, script: String): Pair<WebView, JSONObject>? {
        val views = mutableListOf<WebView>()
        scenario.onActivity { activity ->
            views += webViews(activity.window.decorView).filter { it.isShown && it.getGlobalVisibleRect(Rect()) }
        }
        for (view in views) {
            val raw = withContext(Dispatchers.Main) {
                suspendCancellableCoroutine<String?> { continuation ->
                    view.evaluateJavascript(script) { value -> if (continuation.isActive) continuation.resume(value) }
                }
            }
            val value = runCatching { JSONArray("[$raw]").opt(0) as? JSONObject }.getOrNull()
            if (value != null) return view to value
        }
        return null
    }

    private fun webViews(view: View): List<WebView> = when (view) {
        is WebView -> listOf(view)
        is ViewGroup -> (0 until view.childCount).flatMap { webViews(view.getChildAt(it)) }
        else -> emptyList()
    }

    private fun tap(scenario: ActivityScenario<EbookReaderActivity>, target: Pair<WebView, JSONObject>) {
        scenario.onActivity { activity ->
            val point = windowPoint(target)
            val downTime = SystemClock.uptimeMillis()
            for ((offset, action) in listOf(0L to MotionEvent.ACTION_DOWN, 60L to MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(downTime, downTime + offset, action, point.first, point.second, 0)
                event.source = InputDevice.SOURCE_TOUCHSCREEN
                activity.dispatchTouchEvent(event)
                event.recycle()
            }
        }
    }

    private fun pinch(scenario: ActivityScenario<EbookReaderActivity>, target: Pair<WebView, JSONObject>) {
        scenario.onActivity { activity ->
            val center = windowPoint(target)
            val density = activity.resources.displayMetrics.density
            val downTime = SystemClock.uptimeMillis()
            var tick = 0L
            fun send(action: Int, span: Float, two: Boolean) {
                val count = if (two) 2 else 1
                val properties = Array(count) { index -> MotionEvent.PointerProperties().apply { id = index; toolType = MotionEvent.TOOL_TYPE_FINGER } }
                val coords = Array(count) { index -> MotionEvent.PointerCoords().apply {
                    x = center.first + if (index == 0) -span / 2 else span / 2
                    y = center.second
                    pressure = 1f
                    size = 1f
                } }
                val event = MotionEvent.obtain(downTime, downTime + tick, action, count, properties, coords,
                    0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
                activity.dispatchTouchEvent(event)
                event.recycle()
                tick += 25
            }
            val start = 80f * density
            val finish = start * 1.35f
            send(MotionEvent.ACTION_DOWN, start, false)
            send(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), start, true)
            for (step in 1..6) send(MotionEvent.ACTION_MOVE, start + (finish - start) * step / 6, true)
            send(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), finish, true)
            send(MotionEvent.ACTION_UP, finish, false)
        }
    }

    private fun windowPoint(target: Pair<WebView, JSONObject>): Pair<Float, Float> {
        val view = target.first
        val rect = target.second
        val location = IntArray(2)
        view.getLocationInWindow(location)
        val scale = view.width / rect.getDouble("viewportWidth")
        return (location[0] + rect.getDouble("x") * scale).toFloat() to
            (location[1] + rect.getDouble("y") * scale).toFloat()
    }

    private suspend fun await(description: String, condition: suspend () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 15_000L
        while (!condition()) {
            check(SystemClock.elapsedRealtime() < deadline) { description }
            delay(75)
        }
    }

    private fun writeEPUB(file: File) {
        val bitmap = Bitmap.createBitmap(640, 320, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        val paint = Paint().apply { color = Color.rgb(240, 140, 20) }
        canvas.drawRect(20f, 20f, 620f, 300f, paint)
        paint.color = Color.BLACK
        canvas.drawCircle(320f, 160f, 90f, paint)
        val raster = ByteArrayOutputStream().use { bytes -> bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes); bytes.toByteArray() }
        bitmap.recycle()
        val wideWord = "WIDE".repeat(35)
        val preText = "PRE_CONTENT_".repeat(30)
        val entries = linkedMapOf(
            "mimetype" to "application/epub+zip",
            "META-INF/container.xml" to """<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""",
            "book.opf" to """<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">render-fixture</dc:identifier><dc:title>Rendering fixture</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-29T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="wide" href="wide.xhtml" media-type="application/xhtml+xml"/><item id="image" href="image.xhtml" media-type="application/xhtml+xml"/><item id="raster" href="diagram%23one.png" media-type="image/png"/></manifest><spine><itemref idref="wide"/><itemref idref="image"/></spine></package>""",
            "nav.xhtml" to """<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="wide.xhtml">Wide content</a></li><li><a href="image.xhtml">Illustration</a></li></ol></nav></body></html>""",
            "wide.xhtml" to """<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Wide content</title></head><body><table id="wide-table" style="width:2400px;table-layout:auto"><tr><td>$wideWord</td><td>$wideWord</td></tr></table><table id="small-table" style="width:128px;table-layout:auto;border-collapse:separate;border-spacing:7px"><tr><td>Small</td><td>Table</td></tr></table><pre id="wide-pre" style="width:2400px;white-space:pre">$preText</pre></body></html>""",
            "image.xhtml" to """<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Illustration</title></head><body><p id="pinch-text">Pinch this ordinary text to change its rendered size.</p><figure style="margin:100px auto 12px;text-align:center"><img id="fixture-image" src="diagram%23one.png" alt="Synthetic raster diagram" style="display:block;width:160px;height:80px;margin:0 auto"/><figcaption>Synthetic figure caption</figcaption></figure></body></html>""",
        )
        ZipOutputStream(file.outputStream()).use { zip ->
            for ((name, text) in entries) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(text.toByteArray())
                zip.closeEntry()
            }
            zip.putNextEntry(ZipEntry("diagram#one.png"))
            zip.write(raster)
            zip.closeEntry()
        }
    }

    private fun imageRectScript(): String = rectScript("fixture-image")
    private fun textRectScript(): String = rectScript("pinch-text")

    private fun rectScript(id: String): String = """
        (() => {
            const foliate = document.querySelector('foliate-view');
            const docs = foliate?.renderer?.getContents?.().map(x => x.doc) ?? [document];
            for (const doc of docs) {
                const el = doc.getElementById('$id');
                if (!el) continue;
                const rect = Array.from(el.getClientRects()).find(r => r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < doc.defaultView.innerHeight && r.right > 0 && r.left < doc.defaultView.innerWidth);
                if (!rect) continue;
                let x = (Math.max(0, rect.left) + Math.min(doc.defaultView.innerWidth, rect.right)) / 2;
                let y = (Math.max(0, rect.top) + Math.min(doc.defaultView.innerHeight, rect.bottom)) / 2;
                const frame = doc.defaultView.frameElement;
                if (frame) { const r = frame.getBoundingClientRect(); x += r.left; y += r.top; }
                if (x <= 0 || x >= innerWidth || y <= 0 || y >= innerHeight) continue;
                return {x, y, naturalWidth: el.naturalWidth, src:el.getAttribute("src"), resource:el.getAttribute("data-enve-resource"), viewportWidth: innerWidth, fontSize: parseFloat(doc.defaultView.getComputedStyle(el).fontSize)};
            }
            return null;
        })()
    """.trimIndent()

    private companion object {
        val FIT_METRICS = """
            (() => {
                const foliate = document.querySelector('foliate-view');
                const docs = foliate?.renderer?.getContents?.().map(x => x.doc) ?? [document];
                for (const doc of docs) {
                    const wide = doc.getElementById('wide-table'), pre = doc.getElementById('wide-pre'), small = doc.getElementById('small-table');
                    if (!wide || !pre || !small) continue;
                    const win = doc.defaultView;
                    const available = el => { const p = el.parentElement, s = win.getComputedStyle(p); return p.clientWidth - parseFloat(s.paddingLeft) - parseFloat(s.paddingRight); };
                    const maxRect = el => Math.max(0, ...Array.from(el.getClientRects(), r => r.width));
                    const range = doc.createRange(); range.selectNodeContents(pre);
                    const tableText = doc.createRange(); tableText.selectNodeContents(wide);
                    const smallStyle = win.getComputedStyle(small);
                    return {available: available(wide), preAvailable: available(pre),
                        wideMax: Math.max(maxRect(wide), ...Array.from(tableText.getClientRects(), r => r.width)),
                        preMax: Math.max(maxRect(pre), ...Array.from(range.getClientRects(), r => r.width)),
                        smallWidth: maxRect(small), smallLayout: smallStyle.tableLayout, smallSpacing: smallStyle.borderSpacing, smallInlineSpacing: small.style.borderSpacing,
                        smallHasFitAttribute: Array.from(small.attributes).some(a => a.name.startsWith('data-enve-fit-'))};
                }
                return null;
            })()
        """.trimIndent()
    }
}
