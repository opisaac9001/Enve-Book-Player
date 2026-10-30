package com.enve.app.ui.screens

import android.content.Context
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import org.junit.Rule
import com.enve.core.reader.ReadAloudHighlightStyle
import kotlinx.coroutines.flow.first
import android.webkit.WebView
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.swipeLeft
import androidx.test.espresso.action.ViewActions.swipeRight
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import org.hamcrest.Matchers.allOf
import androidx.test.espresso.matcher.ViewMatchers.isAssignableFrom
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.app.viewmodel.ReaderViewModel
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.reader.ReaderEngineKind
import dagger.hilt.android.EntryPointAccessors
import java.io.File
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.readium.r2.navigator.epub.EpubNavigatorFragment

@RunWith(AndroidJUnit4::class)
class ReaderScrollingNavigationTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun sharedCfiOpensTheExactChapterForALocalBook() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use { await { coordinator.activeRuntime.value != null } }
        val component = checkNotNull(coordinator.activeRuntime.value).component
        val id = "shared-cfi-${UUID.randomUUID()}"
        val file = File(component.storageLocations().cacheDirectory, "ebooks/$id.epub")
        file.parentFile!!.mkdirs()
        writeBook(file)
        val locator = """{"enveSharedPosition":true,"locations":{"cfi":"epubcfi(/6/4!/4/100[p50]/1:0)","enveSourceEngine":"foliate","totalProgression":0}}"""
        val book = Book(id, "Local shared CFI fixture", source = BookSource.LOCAL,
            mediaType = AppMediaType.EBOOK, primaryFileType = "EPUB", epubProgress = 0f,
            readProgress = 0f, epubLocator = locator, lastReadTime = System.currentTimeMillis())
        component.bookCacheDao().upsert(listOf(book.toCachedBook()))
        try {
            val intent = EbookReaderActivity.createIntent(context, id, BookSource.LOCAL,
                title = book.title, author = "Enve tests", bookFormat = "EPUB",
                epubLocator = locator, epubProgress = 0f, readerEngine = ReaderEngineKind.READIUM)
            ActivityScenario.launch<EbookReaderActivity>(intent).use { scenario ->
                await(description = { "The CFI should open chapter two even though percentage points to chapter one" }) {
                    var href: String? = null
                    scenario.onActivity { activity ->
                        href = activity.supportFragmentManager.fragments.filterIsInstance<EpubNavigatorFragment>()
                            .firstOrNull()?.currentLocator?.value?.href?.toString()
                    }
                    href?.endsWith("two.xhtml") == true
                }
            }
        } finally {
            component.bookCacheDao().deleteByCacheKeys(listOf(book.uniqueKey))
            file.delete()
        }
    }

    @Test
    fun userNavigationAfterUnresolvedRestoreSurvivesClosingAndReopening() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use { await { coordinator.activeRuntime.value != null } }
        val component = checkNotNull(coordinator.activeRuntime.value).component
        val id = "unresolved-restore-${UUID.randomUUID()}"
        val file = File(component.storageLocations().cacheDirectory, "ebooks/$id.epub")
        file.parentFile!!.mkdirs()
        writeBook(file)
        val staleLocator = """{"href":"missing-chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.32,"progression":0.32}}"""
        val book = Book(id, "Unresolved restore fixture", source = BookSource.LOCAL,
            mediaType = AppMediaType.EBOOK, primaryFileType = "EPUB", epubProgress = 0.32f,
            readProgress = 0.32f, epubLocator = staleLocator)
        component.bookCacheDao().upsert(listOf(book.toCachedBook()))
        fun intent(locator: String?, progress: Float) = EbookReaderActivity.createIntent(context,
            id, BookSource.LOCAL, title = book.title, author = "Enve tests", bookFormat = "EPUB",
            epubLocator = locator, epubProgress = progress, readerEngine = ReaderEngineKind.READIUM)
        try {
            ActivityScenario.launch<EbookReaderActivity>(intent(staleLocator, 0.32f)).use { scenario ->
                lateinit var vm: ReaderViewModel
                var nav: EpubNavigatorFragment? = null
                await {
                    scenario.onActivity { activity ->
                        vm = ViewModelProvider(activity)[ReaderViewModel::class.java]
                        nav = activity.supportFragmentManager.fragments.filterIsInstance<EpubNavigatorFragment>().firstOrNull()
                    }
                    nav != null && vm.state.value.totalPages > 1
                }
                kotlinx.coroutines.delay(1200)
                withContext(Dispatchers.Main) { vm.seekToProgress(0.8f) }
                await { vm.state.value.progressPct > 40 }
                val destination = checkNotNull(nav!!.currentLocator.value.locations.totalProgression).toFloat()
                withContext(Dispatchers.Main) { vm.flushProgress() }
                await(description = { "User navigation was not saved after an unresolved restore" }) {
                    kotlin.math.abs((component.bookCacheDao().getById(id)?.epubProgress ?: 0f) - destination) < 0.001f
                }
            }
            val saved = checkNotNull(component.bookCacheDao().getById(id))
            ActivityScenario.launch<EbookReaderActivity>(intent(saved.epubLocator, saved.epubProgress!!)).use { scenario ->
                await {
                    var progress = 0
                    scenario.onActivity { progress = ViewModelProvider(it)[ReaderViewModel::class.java].state.value.progressPct }
                    progress > 40
                }
            }
        } finally {
            component.bookCacheDao().deleteByCacheKeys(listOf(book.uniqueKey))
            file.delete()
        }
    }

    @Test
    fun underlineSelectionPersistsAndChangesTheRenderedNarration() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use { await { coordinator.activeRuntime.value != null } }
        val runtime = checkNotNull(coordinator.activeRuntime.value)
        val id = "underline-fixture-${UUID.randomUUID()}"
        val file = File(runtime.component.storageLocations().cacheDirectory, "ebooks/$id.epub")
        file.parentFile!!.mkdirs()
        writeBook(file, narrated = true, longNarration = true)
        val intent = EbookReaderActivity.createIntent(context, id, BookSource.LOCAL,
            title = "Underline fixture", author = "Enve tests", bookFormat = "EPUB",
            epubLocator = null, epubProgress = 0f, readerEngine = ReaderEngineKind.READIUM)
        try {
            ActivityScenario.launch<EbookReaderActivity>(intent).use { scenario ->
                lateinit var vm: ReaderViewModel
                var nav: EpubNavigatorFragment? = null
                await {
                    scenario.onActivity { activity ->
                        vm = ViewModelProvider(activity)[ReaderViewModel::class.java]
                        nav = activity.supportFragmentManager.fragments.filterIsInstance<EpubNavigatorFragment>().firstOrNull()
                    }
                    nav != null && vm.state.value.readAlongSupported
                }
                val navigator = checkNotNull(nav)
                val original = vm.state.value.prefs
                try {
                    withContext(Dispatchers.Main) {
                        vm.updatePreferences(original.copy(readAloudHighlight = true, readAloudHighlightStyle = ReadAloudHighlightStyle.HIGHLIGHT))
                        vm.showReadAloudSheet(true)
                    }
                    compose.onNodeWithText("Underline").performScrollTo().performClick()
                    await { runtime.component.preferences().readAloudHighlightStyle.first() == ReadAloudHighlightStyle.UNDERLINE }
                    withContext(Dispatchers.Main) {
                        vm.showReadAloudSheet(false)
                        vm.toggleReadAlongPlayback()
                    }
                    await { javascript(navigator, "Array.from(document.querySelectorAll('[class*=r2-underline-]')).some(e => getComputedStyle(e).borderBottomWidth !== '0px' && getComputedStyle(e).backgroundColor === 'rgba(0, 0, 0, 0)')") == "true" }
                    val session = runtime.component.readAloud().state.value.sessionId
                    withContext(Dispatchers.Main) { vm.showReadAloudSheet(true) }
                    compose.onNodeWithText("Highlight", substring = false).performScrollTo().performClick()
                    withContext(Dispatchers.Main) { vm.showReadAloudSheet(false) }
                    await { javascript(navigator, "document.querySelectorAll('[class*=r2-highlight-]').length > 0 && document.querySelectorAll('[class*=r2-underline-]').length === 0") == "true" }
                    assertEquals(session, runtime.component.readAloud().state.value.sessionId)
                    assertTrue(runtime.component.readAloud().state.value.isPlaying)
                } finally {
                    runtime.component.readAloud().stopActiveAndAwait()
                    withContext(Dispatchers.Main) { vm.updatePreferences(original) }
                    await { runtime.component.preferences().readAloudHighlightStyle.first() == original.readAloudHighlightStyle }
                }
            }
        } finally { file.delete() }
    }

    @Test
    fun disabledAudioSkippingPreservesPlaybackDuringPagedNavigation() = verifyIndependentNavigation(scroll = false)

    @Test
    fun disabledAudioSkippingPreservesPlaybackDuringScrolledNavigation() = verifyIndependentNavigation(scroll = true)

    private fun verifyIndependentNavigation(scroll: Boolean) = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use { await { coordinator.activeRuntime.value != null } }
        val runtime = checkNotNull(coordinator.activeRuntime.value)
        val playback = runtime.component.readAloud()
        val id = "independent-navigation-${UUID.randomUUID()}"
        val file = File(runtime.component.storageLocations().cacheDirectory, "ebooks/$id.epub")
        file.parentFile!!.mkdirs()
        writeBook(file, narrated = true, longNarration = true)
        val intent = EbookReaderActivity.createIntent(context, id, BookSource.LOCAL,
            title = "Independent navigation fixture", author = "Enve tests", bookFormat = "EPUB",
            epubLocator = null, epubProgress = 0f, readerEngine = ReaderEngineKind.READIUM)
        try {
            ActivityScenario.launch<EbookReaderActivity>(intent).use { scenario ->
                lateinit var vm: ReaderViewModel
                var nav: EpubNavigatorFragment? = null
                await {
                    scenario.onActivity { activity ->
                        vm = ViewModelProvider(activity)[ReaderViewModel::class.java]
                        nav = activity.supportFragmentManager.fragments.filterIsInstance<EpubNavigatorFragment>().firstOrNull()
                    }
                    nav != null && vm.state.value.readAlongSupported
                }
                val navigator = checkNotNull(nav)
                val original = vm.state.value.prefs
                try {
                    withContext(Dispatchers.Main) {
                        vm.updatePreferences(original.copy(scroll = scroll, readAloudAutoTurn = false, readAloudSkipOnPageTurn = false))
                    }
                    kotlinx.coroutines.delay(500)
                    withContext(Dispatchers.Main) { vm.toggleReadAlongPlayback() }
                    await { playback.state.value.isPlaying && playback.state.value.positionMs > 500 }
                    withContext(Dispatchers.Main) { vm.toggleReadAlongPlayback() }
                    await { !playback.state.value.isPlaying && !playback.state.value.playWhenReady }
                    val session = playback.state.value.sessionId
                    val pausedAt = playback.state.value.positionMs
                    for (playing in listOf(false, true)) {
                        if (playing) {
                            withContext(Dispatchers.Main) { vm.toggleReadAlongPlayback() }
                            await { playback.state.value.isPlaying }
                        }
                        val before = navigator.currentLocator.value
                        withContext(Dispatchers.Main) { vm.pageForward() }
                        await { navigator.currentLocator.value != before }
                        withContext(Dispatchers.Main) { vm.pageBackward() }
                        kotlinx.coroutines.delay(250)
                        withContext(Dispatchers.Main) { vm.seekToProgress(0.8f) }
                        await(description = { "Progress seek ended at ${navigator.currentLocator.value.toJSON()}" }) {
                            navigator.currentLocator.value.href.toString().endsWith("two.xhtml")
                        }
                        kotlinx.coroutines.delay(600)
                        if (!playing) assertEquals(pausedAt, playback.state.value.positionMs)
                        else assertTrue(playback.state.value.positionMs < 30000)
                        val second = vm.state.value.tocEntries.first { it.href.endsWith("two.xhtml") }
                        withContext(Dispatchers.Main) { vm.navigateTo(second) }
                        await { navigator.currentLocator.value.href.toString().endsWith("two.xhtml") }
                        kotlinx.coroutines.delay(600)
                        assertEquals(session, playback.state.value.sessionId)
                        assertTrue("Reading chapter two must not seek audio to 60 seconds", playback.state.value.positionMs < 30000)
                        if (!playing) assertEquals(pausedAt, playback.state.value.positionMs)
                        else assertTrue(playback.state.value.isPlaying)
                        val first = vm.state.value.tocEntries.first { it.href.endsWith("one.xhtml") }
                        withContext(Dispatchers.Main) { vm.navigateTo(first) }
                        await { navigator.currentLocator.value.href.toString().endsWith("one.xhtml") }
                        kotlinx.coroutines.delay(600)
                        if (!playing) assertEquals(pausedAt, playback.state.value.positionMs)
                    }
                    withContext(Dispatchers.Main) {
                        vm.updatePreferences(vm.state.value.prefs.copy(readAloudSkipOnPageTurn = true))
                        vm.navigateTo(vm.state.value.tocEntries.first { it.href.endsWith("two.xhtml") })
                    }
                    await { playback.state.value.positionMs >= 60000 }
                } finally {
                    playback.stopActiveAndAwait()
                    withContext(Dispatchers.Main) { vm.updatePreferences(original) }
                    kotlinx.coroutines.delay(250)
                }
            }
        } finally { file.delete() }
    }

    @Test
    fun readAlongCentersTheNextOffscreenPassage() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use {
            await { coordinator.activeRuntime.value != null }
        }
        val runtime = checkNotNull(coordinator.activeRuntime.value)
        val id = "centering-fixture-${UUID.randomUUID()}"
        val file = File(runtime.component.storageLocations().cacheDirectory, "ebooks/$id.epub")
        file.parentFile!!.mkdirs()
        writeBook(file, narrated = true)
        val intent = EbookReaderActivity.createIntent(context, id, BookSource.LOCAL,
            title = "Read-along centering fixture", author = "Enve tests", bookFormat = "EPUB",
            epubLocator = null, epubProgress = 0f, readerEngine = ReaderEngineKind.READIUM)
        try {
            ActivityScenario.launch<EbookReaderActivity>(intent).use { scenario ->
                lateinit var vm: ReaderViewModel
                var nav: EpubNavigatorFragment? = null
                await {
                    scenario.onActivity { activity ->
                        vm = ViewModelProvider(activity)[ReaderViewModel::class.java]
                        nav = activity.supportFragmentManager.fragments.filterIsInstance<EpubNavigatorFragment>().firstOrNull()
                    }
                    nav != null
                }
                val navigator = checkNotNull(nav)
                val original = vm.state.value.prefs
                try {
                    withContext(Dispatchers.Main) {
                        vm.updatePreferences(original.copy(scroll = true, readAloudAutoTurn = true))
                    }
                    await { javascript(navigator, "document.documentElement.scrollHeight > window.innerHeight * 3") == "true" }
                    assertTrue(javascript(navigator, "document.getElementById('p50').getBoundingClientRect().top > window.innerHeight") == "true")
                    withContext(Dispatchers.Main) { vm.toggleReadAlongPlayback() }
                    await {
                        javascript(navigator, "Math.abs(document.getElementById('p50').getBoundingClientRect().top + document.getElementById('p50').getBoundingClientRect().height / 2 - window.innerHeight / 2) < window.innerHeight * 0.15") == "true"
                    }
                    assertTrue(vm.state.value.readAlongPlaying)
                } finally {
                    withContext(Dispatchers.Main) { vm.updatePreferences(original) }
                    kotlinx.coroutines.delay(250)
                }
            }
        } finally {
            file.delete()
        }
    }

    @Test
    fun scrollingTapsMoveWithinChapterAndHorizontalSwipesDoNotChangeChapter() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use {
            await { coordinator.activeRuntime.value != null }
        }
        val runtime = checkNotNull(coordinator.activeRuntime.value)
        val id = "scroll-fixture-${UUID.randomUUID()}"
        val file = File(runtime.component.storageLocations().cacheDirectory, "ebooks/$id.epub")
        file.parentFile!!.mkdirs()
        writeBook(file)
        val intent = EbookReaderActivity.createIntent(context, id, BookSource.LOCAL,
            title = "Scrolling navigation fixture", author = "Enve tests", bookFormat = "EPUB",
            epubLocator = null, epubProgress = 0f, readerEngine = ReaderEngineKind.READIUM)
        try {
            ActivityScenario.launch<EbookReaderActivity>(intent).use { scenario ->
                lateinit var vm: ReaderViewModel
                var nav: EpubNavigatorFragment? = null
                await {
                    scenario.onActivity { activity ->
                        vm = ViewModelProvider(activity)[ReaderViewModel::class.java]
                        nav = activity.supportFragmentManager.fragments.filterIsInstance<EpubNavigatorFragment>().firstOrNull()
                    }
                    nav != null
                }
                val navigator = checkNotNull(nav)
                val original = vm.state.value.prefs
                try {
                    withContext(Dispatchers.Main) { vm.updatePreferences(original.copy(scroll = true)) }
                    await { javascript(navigator, "document.documentElement.scrollHeight > window.innerHeight * 3") == "true" }
                    val href = navigator.currentLocator.value.href
                    withContext(Dispatchers.Main) { vm.pageForward() }
                    await { javascript(navigator, "window.scrollY").toDoubleOrNull()?.let { it > 100 } == true }
                    val forward = javascript(navigator, "window.scrollY").toDouble()
                    assertEquals(href, navigator.currentLocator.value.href)
                    withContext(Dispatchers.Main) { vm.pageBackward() }
                    await { javascript(navigator, "window.scrollY").toDoubleOrNull()?.let { it < forward / 2 } == true }
                    onView(allOf(isAssignableFrom(WebView::class.java), isDisplayed())).perform(swipeLeft(), swipeRight())
                    assertEquals(href, navigator.currentLocator.value.href)
                    withContext(Dispatchers.Main) { vm.updatePreferences(original.copy(scroll = false)) }
                    await { javascript(navigator, "document.documentElement.scrollHeight <= window.innerHeight * 1.1") == "true" }
                    val before = navigator.currentLocator.value.locations.progression ?: 0.0
                    withContext(Dispatchers.Main) { vm.pageForward() }
                    await { (navigator.currentLocator.value.locations.progression ?: 0.0) > before }
                    assertTrue((navigator.currentLocator.value.locations.progression ?: 0.0) > before)
                } finally {
                    withContext(Dispatchers.Main) { vm.updatePreferences(original) }
                    kotlinx.coroutines.delay(250)
                }
            }
        } finally {
            file.delete()
        }
    }

    @Test
    fun closingDuringFontReflowKeepsTheSavedPassage() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use { await { coordinator.activeRuntime.value != null } }
        val component = checkNotNull(coordinator.activeRuntime.value).component
        val id = "reflow-close-${UUID.randomUUID()}"
        val file = File(component.storageLocations().cacheDirectory, "ebooks/$id.epub")
        file.parentFile!!.mkdirs()
        writeBook(file)
        val book = Book(id, "Reflow close fixture", source = BookSource.LOCAL,
            mediaType = AppMediaType.EBOOK, primaryFileType = "EPUB")
        component.bookCacheDao().upsert(listOf(book.toCachedBook()))
        fun intent(locator: String?, progress: Float) = EbookReaderActivity.createIntent(context,
            id, BookSource.LOCAL, title = book.title, author = "Enve tests", bookFormat = "EPUB",
            epubLocator = locator, epubProgress = progress, readerEngine = ReaderEngineKind.READIUM)
        try {
            var expected = 0f
            ActivityScenario.launch<EbookReaderActivity>(intent(null, 0f)).use { scenario ->
                lateinit var vm: ReaderViewModel
                var nav: EpubNavigatorFragment? = null
                await {
                    scenario.onActivity { activity ->
                        vm = ViewModelProvider(activity)[ReaderViewModel::class.java]
                        nav = activity.supportFragmentManager.fragments.filterIsInstance<EpubNavigatorFragment>().firstOrNull()
                    }
                    nav != null && vm.state.value.totalPages > 1
                }
                val original = vm.state.value.prefs
                try {
                    kotlinx.coroutines.delay(800)
                    withContext(Dispatchers.Main) { vm.seekToProgress(0.75f) }
                    await(description = { "Seek did not settle: ${vm.state.value.progressPct}%, locator=${nav?.currentLocator?.value}, prefs=${vm.state.value.prefs.scroll}" }) { vm.state.value.progressPct in 50..99 }
                    kotlinx.coroutines.delay(400)
                    expected = nav!!.currentLocator.value.locations.totalProgression!!.toFloat()
                    withContext(Dispatchers.Main) {
                        vm.updatePreferences(original.copy(fontSize = if (original.fontSize < 1.5f) 1.8f else 1f))
                        vm.flushProgress()
                    }
                    await(description = { "Closing during font reflow lost the held location" }) {
                        kotlin.math.abs((component.bookCacheDao().getById(id)?.epubProgress ?: 0f) - expected) < 0.001f
                    }
                } finally {
                    withContext(Dispatchers.Main) { vm.updatePreferences(original) }
                }
            }
            val saved = checkNotNull(component.bookCacheDao().getById(id))
            ActivityScenario.launch<EbookReaderActivity>(intent(saved.epubLocator, saved.epubProgress!!)).use { scenario ->
                await {
                    var progress = 0
                    scenario.onActivity { progress = ViewModelProvider(it)[ReaderViewModel::class.java].state.value.progressPct }
                    kotlin.math.abs(progress - (expected * 100).toInt()) <= 2
                }
            }
        } finally {
            component.bookCacheDao().deleteByCacheKeys(listOf(book.uniqueKey))
            file.delete()
        }
    }

    private suspend fun javascript(nav: EpubNavigatorFragment, expression: String): String =
        withContext(Dispatchers.Main) { nav.evaluateJavascript(expression).orEmpty() }

    private suspend fun await(description: () -> String = { "Reader did not reach the expected state" }, condition: suspend () -> Boolean) {
        val deadline = android.os.SystemClock.elapsedRealtime() + 20000
        while (!condition()) {
            check(android.os.SystemClock.elapsedRealtime() < deadline) { description() }
            kotlinx.coroutines.delay(100)
        }
    }

    private fun writeBook(file: File, narrated: Boolean = false, longNarration: Boolean = false) {
        ZipOutputStream(file.outputStream()).use { zip ->
            fun entry(name: String, value: String) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(value.toByteArray())
                zip.closeEntry()
            }
            entry("mimetype", "application/epub+zip")
            entry("META-INF/container.xml", """<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""")
            val secondOverlay = if (longNarration) """<item id="overlay-two" href="two.smil" media-type="application/smil+xml"/>""" else ""
            val secondAttribute = if (longNarration) """ media-overlay="overlay-two"""" else ""
            val overlayManifest = if (narrated) """<item id="overlay" href="one.smil" media-type="application/smil+xml"/><item id="audio" href="narration.wav" media-type="audio/wav"/>""" else ""
            val overlayAttribute = if (narrated) """ media-overlay="overlay"""" else ""
            entry("book.opf", """<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">scroll-fixture</dc:identifier><dc:title>Scrolling fixture</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-11T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"$overlayAttribute/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"$secondAttribute/>$overlayManifest$secondOverlay</manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>""")
            entry("nav.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="one.xhtml">One</a></li><li><a href="two.xhtml">Two</a></li></ol></nav></body></html>""")
            if (narrated) {
                val boundary = if (longNarration) 30 else 2
                val end = if (longNarration) 60 else 10
                if (longNarration) entry("two.smil", """<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><seq><par><text src="two.xhtml#p1"/><audio src="narration.wav" clipBegin="60s" clipEnd="90s"/></par><par><text src="two.xhtml#p50"/><audio src="narration.wav" clipBegin="90s" clipEnd="120s"/></par></seq></body></smil>""")
                entry("one.smil", """<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><seq><par><text src="one.xhtml#p1"/><audio src="narration.wav" clipBegin="0s" clipEnd="${boundary}s"/></par><par><text src="one.xhtml#p50"/><audio src="narration.wav" clipBegin="${boundary}s" clipEnd="${end}s"/></par></seq></body></smil>""")
                val pcmSize = if (longNarration) 1920000 else 160000
                val wav = java.nio.ByteBuffer.allocate(44 + pcmSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    .put("RIFF".toByteArray()).putInt(36 + pcmSize).put("WAVEfmt ".toByteArray())
                    .putInt(16).putShort(1).putShort(1).putInt(8000).putInt(16000)
                    .putShort(2).putShort(16).put("data".toByteArray()).putInt(pcmSize).array()
                zip.putNextEntry(ZipEntry("narration.wav"))
                zip.write(wav)
                zip.closeEntry()
            }
            for (chapter in listOf("one", "two")) {
                val paragraphs = (1..100).joinToString("") { "<p id='p$it'>Chapter $chapter, paragraph $it. This text fills the reader with enough content to verify scrolling and page turns on a real device.</p>" }
                entry("$chapter.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml"><head><title>$chapter</title></head><body>$paragraphs</body></html>""")
            }
        }
    }
}
