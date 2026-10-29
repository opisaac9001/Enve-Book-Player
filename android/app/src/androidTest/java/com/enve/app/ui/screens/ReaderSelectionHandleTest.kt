package com.enve.app.ui.screens

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Rect
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.CoordinatesProvider
import androidx.test.espresso.action.GeneralClickAction
import androidx.test.espresso.action.Press
import androidx.test.espresso.action.Tap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.MainActivity
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
import org.hamcrest.Description
import org.hamcrest.TypeSafeMatcher
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import kotlin.coroutines.resume

@RunWith(AndroidJUnit4::class)
class ReaderSelectionHandleTest {
    @Test
    fun firstWordSelectionCapturesNativeHandlesForBothEngines() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val xhtml = instrumentation.context.assets.open("reader/hyphenated-first-word.xhtml").bufferedReader().use { it.readText() }
        val output = File(context.cacheDir, "selection-handles").also { check(it.isDirectory || it.mkdirs()) }
        val coordinator = EntryPointAccessors.fromApplication(context,
            ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use {
            await("profile runtime ready") { coordinator.activeRuntime.value != null }
        }
        val component = checkNotNull(coordinator.activeRuntime.value).component
        val lastOpened = component.lastOpenedBookStore()
        val previousLastOpened = lastOpened.lastOpenedBookKey.first()
        val failures = mutableListOf<String>()
        for (engine in ReaderEngineKind.entries) {
            val id = "selection-handles-${UUID.randomUUID()}"
            val file = File(component.storageLocations().cacheDirectory, "ebooks/$id.epub")
            check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
            writeEPUB(file, xhtml)
            val book = Book(id = id, title = "Hyphenated first-word fixture", source = BookSource.LOCAL,
                mediaType = AppMediaType.EBOOK, primaryFileType = "EPUB")
            component.bookCacheDao().upsert(listOf(book.toCachedBook()))
            var vm: ReaderViewModel? = null
            var original: ReaderPreferences? = null
            val scenario = ActivityScenario.launch<EbookReaderActivity>(EbookReaderActivity.createIntent(
                context, id, BookSource.LOCAL, title = book.title, author = "Enve tests", bookFormat = "EPUB",
                epubLocator = null, epubProgress = 0f, readerEngine = engine))
            try {
                await("$engine reader ready") {
                    var matches = false
                    scenario.onActivity { activity ->
                        vm = ViewModelProvider(activity)[ReaderViewModel::class.java]
                        val readium = activity.supportFragmentManager.fragments.any { it is EpubNavigatorFragment }
                        val foliate = webViews(activity.window.decorView).any {
                            it.isShown && it.url?.contains("/assets/foliate-reader.html") == true
                        }
                        matches = if (engine == ReaderEngineKind.READIUM) readium else foliate && !readium
                    }
                    matches && checkNotNull(vm).state.value.totalPages > 0
                }
                val reader = checkNotNull(vm)
                val baseline = reader.state.value.prefs
                original = baseline
                withContext(Dispatchers.Main) {
                    reader.updatePreferences(baseline.copy(publisherStyles = true, justified = true,
                        fontSize = 1f, scroll = false))
                }
                delay(600)
                for (paragraph in listOf("auto", "soft")) {
                    withContext(Dispatchers.Main) {
                        reader.navigateTo(TocEntry(paragraph, paragraph, "fixture.xhtml#$paragraph", 0))
                    }
                    var target: Pair<WebView, JSONObject>? = null
                    await("$engine #$paragraph first word visible") {
                        target = metrics(scenario, paragraph)
                        target?.second?.optBoolean("wordVisible") == true
                    }
                    val hit = checkNotNull(target)
                    val matcher = object : TypeSafeMatcher<View>() {
                        override fun describeTo(description: Description) { description.appendText("fixture WebView") }
                        override fun matchesSafely(item: View): Boolean = item === hit.first
                    }
                    onView(matcher).perform(GeneralClickAction(Tap.LONG, CoordinatesProvider { view ->
                        val location = IntArray(2)
                        view.getLocationOnScreen(location)
                        val scale = view.width / hit.second.getDouble("viewportWidth")
                        floatArrayOf((location[0] + hit.second.getDouble("x") * scale).toFloat(),
                            (location[1] + hit.second.getDouble("y") * scale).toFloat())
                    }, Press.FINGER, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0))
                    val selectionDeadline = android.os.SystemClock.elapsedRealtime() + 5_000L
                    var selected: JSONObject? = null
                    do {
                        selected = metrics(scenario, paragraph)?.second
                        if (!selected?.optString("selection").isNullOrEmpty()) break
                        delay(100)
                    } while (android.os.SystemClock.elapsedRealtime() < selectionDeadline)
                    delay(500)
                    val stem = "${engine.name.lowercase()}-$paragraph"
                    val screenshot = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
                    File(output, "$stem.png").outputStream().use {
                        check(screenshot.compress(Bitmap.CompressFormat.PNG, 100, it))
                    }
                    screenshot.recycle()
                    val evidence = metrics(scenario, paragraph)?.second ?: selected ?: JSONObject()
                    withContext(Dispatchers.Main) {
                        evidence.put("webViewVersion", WebView.getCurrentWebViewPackage()?.versionName)
                        val location = IntArray(2)
                        hit.first.getLocationOnScreen(location)
                        evidence.put("webViewScreenX", location[0]).put("webViewScreenY", location[1])
                        evidence.put("webViewPixelWidth", hit.first.width).put("webViewPixelHeight", hit.first.height)
                    }
                    evidence.put("engine", engine.name).put("paragraphId", paragraph)
                    File(output, "$stem.json").writeText(evidence.toString(2))
                    val expected = if (paragraph == "auto") "Extraordinarily" else "Incomprehensibility"
                    val actual = evidence.optString("selection").replace("\u00ad", "").trim()
                    if (actual != expected) failures += "$stem DOM selection was '$actual', expected '$expected'"
                    evaluate(hit.first, clearSelectionScript())
                    delay(350)
                }
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
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    private suspend fun metrics(scenario: ActivityScenario<EbookReaderActivity>, paragraph: String): Pair<WebView, JSONObject>? {
        val views = mutableListOf<WebView>()
        scenario.onActivity { activity -> views += webViews(activity.window.decorView)
            .filter { it.isShown && it.getGlobalVisibleRect(Rect()) } }
        for (view in views) {
            val value = runCatching { JSONArray("[${evaluate(view, metricsScript(paragraph))}]").opt(0) as? JSONObject }.getOrNull()
            if (value != null) return view to value
        }
        return null
    }

    private suspend fun evaluate(view: WebView, script: String): String? = withContext(Dispatchers.Main) {
        suspendCancellableCoroutine { continuation ->
            view.evaluateJavascript(script) { value -> if (continuation.isActive) continuation.resume(value) }
        }
    }

    private fun webViews(view: View): List<WebView> = when (view) {
        is WebView -> listOf(view)
        is ViewGroup -> (0 until view.childCount).flatMap { webViews(view.getChildAt(it)) }
        else -> emptyList()
    }

    private suspend fun await(description: String, condition: suspend () -> Boolean) {
        val deadline = android.os.SystemClock.elapsedRealtime() + 20_000L
        while (!condition()) {
            check(android.os.SystemClock.elapsedRealtime() < deadline) { description }
            delay(100)
        }
    }

    private fun writeEPUB(file: File, xhtml: String) {
        val entries = linkedMapOf(
            "mimetype" to "application/epub+zip",
            "META-INF/container.xml" to """<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""",
            "book.opf" to """<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">hyphen-selection-fixture</dc:identifier><dc:title>Selection handles</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-29T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="text" href="fixture.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="text"/></spine></package>""",
            "nav.xhtml" to """<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="fixture.xhtml#auto">Automatic hyphens</a></li><li><a href="fixture.xhtml#soft">Soft hyphens</a></li></ol></nav></body></html>""",
            "fixture.xhtml" to xhtml,
        )
        ZipOutputStream(file.outputStream()).use { zip ->
            for ((name, value) in entries) {
                zip.putNextEntry(ZipEntry(name)); zip.write(value.toByteArray()); zip.closeEntry()
            }
        }
    }

    private fun clearSelectionScript(): String = """
        (() => {
            const docs = document.querySelector('foliate-view')?.renderer?.getContents?.().map(x => x.doc) ?? [document];
            for (const doc of docs) doc.defaultView.getSelection()?.removeAllRanges();
        })()
    """.trimIndent()

    private fun metricsScript(id: String): String = """
        (() => {
            const docs = document.querySelector('foliate-view')?.renderer?.getContents?.().map(x => x.doc) ?? [document];
            const rectJSON = r => ({left:r.left,top:r.top,right:r.right,bottom:r.bottom,width:r.width,height:r.height});
            for (const doc of docs) {
                const p = doc.getElementById('$id');
                if (!p) continue;
                const walker = doc.createTreeWalker(p, NodeFilter.SHOW_TEXT);
                const node = walker.nextNode();
                if (!node) continue;
                const word = node.data.match(/^\S+/)?.[0];
                if (!word) continue;
                const range = doc.createRange(); range.setStart(node, 0); range.setEnd(node, word.length);
                const rects = Array.from(range.getClientRects());
                const win = doc.defaultView;
                const visible = rects.find(r => r.width > 0 && r.height > 0 && r.right > 0 && r.bottom > 0 && r.left < win.innerWidth && r.top < win.innerHeight);
                const frame = win.frameElement?.getBoundingClientRect();
                const x = visible ? (Math.max(0, visible.left) + Math.min(win.innerWidth, visible.right)) / 2 + (frame?.left ?? 0) : 0;
                const y = visible ? (Math.max(0, visible.top) + Math.min(win.innerHeight, visible.bottom)) / 2 + (frame?.top ?? 0) : 0;
                const selection = win.getSelection();
                const selectionRange = selection?.rangeCount ? selection.getRangeAt(0) : null;
                const style = win.getComputedStyle(p);
                return {word,wordVisible:!!visible && x > 0 && x < innerWidth && y > 0 && y < innerHeight,x,y,
                    viewportWidth:innerWidth,viewportHeight:innerHeight,documentViewportWidth:win.innerWidth,
                    wordRects:rects.map(rectJSON),paragraphRects:Array.from(p.getClientRects(),rectJSON),frameRect:frame?rectJSON(frame):null,
                    selection:selection?.toString() ?? '',selectionRects:selectionRange?Array.from(selectionRange.getClientRects(),rectJSON):[],
                    anchorOffset:selection?.anchorOffset,focusOffset:selection?.focusOffset,
                    anchorText:selection?.anchorNode?.textContent,focusText:selection?.focusNode?.textContent,
                    pseudo: Object.fromEntries(Array.from(win.getComputedStyle(p, '::before'), key => [key, win.getComputedStyle(p, '::before').getPropertyValue(key)])),
                    attributes:Array.from(p.attributes, a=>[a.name,a.value]),fixInstalled:!!win.__enveSelectionLead,
                    hyphens:style.hyphens,webkitHyphens:style.webkitHyphens,fontSize:style.fontSize,
                    textAlign:style.textAlign,userAgent:navigator.userAgent,devicePixelRatio:devicePixelRatio};
            }
            return null;
        })()
    """.trimIndent()
}
