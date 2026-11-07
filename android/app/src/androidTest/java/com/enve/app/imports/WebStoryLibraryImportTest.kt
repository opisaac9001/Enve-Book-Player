package com.enve.app.imports

import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.MainActivity
import com.enve.app.cloud.WebStoryImportActivity
import com.enve.app.profiles.ProfileActivityBinding
import dagger.hilt.android.EntryPointAccessors
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.net.InetAddress
import java.util.UUID
import java.util.zip.ZipFile

@RunWith(AndroidJUnit4::class)
class WebStoryLibraryImportTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun serialBecomesAnOfflineEpubInTheCurrentLibrary() = runBlocking<Unit> {
        val title = "Willow walk ${UUID.randomUUID()}"
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val coordinator = EntryPointAccessors.fromApplication(
            context, ProfileActivityBinding.DeviceEntryPoint::class.java,
        ).profiles()
        val component = ActivityScenario.launch(MainActivity::class.java).use {
            withTimeout(20_000) { coordinator.activeRuntime.filterNotNull().first().component }
        }
        val dao = component.bookCacheDao()
        val downloads = component.comicDownloads()
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val body = when (request.path) {
                    "/book" -> """<h1>$title</h1><ul id="chapters"><li><a href="/chapter/21/">The orchard</a></li><li><a href="/chapter/22/">The river</a></li></ul>"""
                    "/chapter/21/" -> """<article><h1>The orchard</h1><p>She counted the trees in the orchard and wrote their names in her notebook as the sun came over the hill.</p><script>fixtureScriptMarker()</script></article>"""
                    "/chapter/22/" -> """<article><h1>The river</h1><p>She crossed the river on the stone bridge, then followed the reeds upstream until she reached the old mill.</p></article>"""
                    else -> return MockResponse().setResponseCode(404)
                }
                return MockResponse().setHeader("Content-Type", "text/html; charset=utf-8")
                    .setBody("""<!doctype html><html lang="en"><head><title>$title</title><meta name="author" content="Enve fixtures"></head><body>$body</body></html>""")
            }
        }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        try {
            ActivityScenario.launch<WebStoryImportActivity>(WebStoryImportActivity.createIntent(context)).use {
                compose.onNode(hasSetTextAction()).performTextInput(server.url("/book").toString())
                click("Preview")
                click("Import 2 chapters")
                click("Done")
            }
            val book = withTimeout(8_000) { dao.observeAllForList().first { rows -> rows.any { it.title == title } } }
                .single { it.title == title }
            assertEquals("LOCAL", book.source)
            assertEquals("Enve fixtures", book.author)
            val file = checkNotNull(downloads.getLocalFile(book.id))
            ZipFile(file).use { zip ->
                val pages = zip.entries().asSequence().filter { it.name.endsWith(".xhtml") }.map {
                    zip.getInputStream(it).bufferedReader().use { reader -> reader.readText() }
                }.toList()
                assertTrue(pages.any { "trees in the orchard" in it })
                assertTrue(pages.any { "crossed the river" in it })
                assertTrue(pages.any { it.contains("epub:type=\"toc\"") && "The orchard" in it && "The river" in it })
                assertFalse(pages.any { "fixtureScriptMarker" in it })
            }
        } finally {
            server.shutdown()
            val fixtures = dao.observeAllForList().first().filter { it.title == title }
            fixtures.forEach { downloads.removeDownload(it.id) }
            dao.deleteByCacheKeys(fixtures.map { it.cacheKey })
        }
    }

    private fun click(label: String) {
        compose.waitUntil(20_000) {
            compose.onAllNodes(hasText(label)).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
        }
        compose.onNodeWithText(label).performScrollTo().performClick()
    }
}
