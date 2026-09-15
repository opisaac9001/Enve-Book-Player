package com.enve.app.readium

import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import android.os.SystemClock
import android.os.Environment
import android.util.Log
import android.webkit.WebView
import android.webkit.WebViewClient
import com.enve.app.ui.screens.reader.ReadiumPortableAnchorScript
import com.enve.app.data.reader.search.EbookSearchService
import com.enve.app.data.reader.search.EbookSearchIndexStore
import java.io.File
import java.io.FileInputStream
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.flow.last
import kotlinx.coroutines.flow.takeWhile
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.Assume.assumeTrue
import org.junit.runner.RunWith
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.getOrElse

@RunWith(AndroidJUnit4::class)
class EbookSearchServiceTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private lateinit var directory: File
    private lateinit var service: EbookSearchService
    private val opened = mutableListOf<Publication>()

    @Before
    fun prepare() {
        directory = File(context.cacheDir, "search-test-${UUID.randomUUID()}").apply { mkdirs() }
        val isolatedContext = object : ContextWrapper(context) {
            override fun getCacheDir(): File = directory
        }
        service = EbookSearchService(EbookSearchIndexStore(isolatedContext))
    }

    @After
    fun cleanUp() {
        opened.forEach { it.close() }
        directory.deleteRecursively()
    }

    @Test
    fun searchesAccentsPhrasesPartialWordsAndLiteralOperators() = runBlocking {
        val file = fixture("<p>A café dictionary contains dictionaries. The quick brown fox.</p><p>東京 日本語.</p><p>cafe&#x301; OR NEAR.</p>")
        val publication = open(file)
        val cafe = service.search(publication, file, "cafe", true, 100).last()
        assertEquals(2, cafe.results.size)
        assertEquals("café", cafe.results.first().text.highlight)
        assertTrue(cafe.results.first().text.before.orEmpty().endsWith("A "))
        assertEquals(1, service.search(publication, file, "dictionary", true, 100).last().results.size)
        assertEquals(2, service.search(publication, file, "diction", false, 100).last().results.size)
        assertEquals(0, service.search(publication, file, "diction", true, 100).last().results.size)
        assertEquals(1, service.search(publication, file, "quick brown", true, 100).last().results.size)
        assertEquals(1, service.search(publication, file, "東京", true, 100).last().results.size)
        assertEquals(1, service.search(publication, file, "OR NEAR", true, 100).last().results.size)
        assertTrue(service.search(publication, file, "\" OR *", true, 100).last().results.isEmpty())
    }

    @Test
    fun ranksHeadingMatchesAndLoadsBeyondOneHundredWithoutDuplicates() = runBlocking {
        val file = fixture(
            (1..125).joinToString("") { "<p>Occurrence $it dictionary definition.</p>" },
            "<h2 id='entry'>Dictionary</h2><p>The entry itself.</p>",
        )
        val publication = open(file)
        val first = service.search(publication, file, "dictionary", true, 100).last()
        assertEquals(100, first.results.size)
        assertTrue(first.hasMore)
        assertTrue(first.results.first().href.toString().endsWith("chapter1.xhtml"))
        val all = service.search(publication, file, "dictionary", true, 200).last()
        assertEquals(126, all.results.size)
        assertFalse(all.hasMore)
        assertEquals(126, all.results.map { "${it.href}:${it.locations.progression}" }.toSet().size)
    }

    @Test
    fun reusesCacheResumesCancellationAndInvalidatesChangedEpub() = runBlocking {
        val file = fixture("<p>First needle.</p>", "<p>Second needle.</p>", "<p>Third needle.</p>")
        val publication = open(file)
        service.search(publication, file, "needle", true, 100)
            .takeWhile { it.indexedSections < 1 }.toList()
        val resumed = service.search(publication, file, "needle", true, 100).toList()
        assertTrue(resumed.first().indexedSections >= 1)
        assertEquals(3, resumed.last().results.size)
        val warm = service.search(publication, file, "needle", true, 100).toList()
        assertTrue(warm.none { it.indexing })
        val changed = fixture("<p>A replacement haystack.</p>", destination = file)
        val replacement = open(changed)
        assertEquals(0, service.search(replacement, changed, "needle", true, 100).last().results.size)
        assertEquals(1, service.search(replacement, changed, "haystack", true, 100).last().results.size)
    }

    @Test
    fun navigatesRepeatedQuotesWithoutChangingTheDocument() = runBlocking {
        withContext(Dispatchers.Main) {
            val webView = WebView(context)
            try {
                webView.settings.javaScriptEnabled = true
                val ready = CompletableDeferred<Unit>()
                webView.webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView, url: String) { ready.complete(Unit) }
                }
                webView.loadDataWithBaseURL(
                    "https://search.test/", "<html><body><p>İ before the first dictionary mention.</p><p id='entry'>A café <em>dictionary</em> definition.</p><script>window.readium={scrollToLocator: value => {window.captured=value;return true;}};</script></body></html>",
                    "text/html", "UTF-8", null,
                )
                withTimeout(10_000) { ready.await() }
                val result = CompletableDeferred<String>()
                webView.evaluateJavascript(
                    ReadiumPortableAnchorScript.restore("""{"text":{"highlight":"dictionary","before":"A café ","after":" definition."}}""", searchResult = true),
                ) { result.complete(it) }
                assertEquals("\"true\"", withTimeout(10_000) { result.await() })
                val captured = CompletableDeferred<String>()
                webView.evaluateJavascript("({selector: captured.locations.cssSelector, highlight: captured.text.highlight, id: document.querySelector('p:nth-of-type(2)').id, spans: document.querySelectorAll('span').length})") { captured.complete(it) }
                val output = JSONObject(withTimeout(10_000) { captured.await() })
                assertEquals("#entry > em:nth-of-type(1)", output.getString("selector"))
                assertEquals("dictionary", output.getString("highlight"))
                assertEquals("entry", output.getString("id"))
                assertEquals(0, output.getInt("spans"))
            } finally {
                webView.destroy()
            }
        }
    }

    @Test
    fun immediatelyReplacesCancelledSearchDuringIndexing() = runBlocking {
        for (pause in listOf(50L, 200L, 500L)) {
            val file = fixture("<p>$pause ${"dictionary definition. ".repeat(40_000)}</p>")
            val publication = open(file)
            val job = launch { service.search(publication, file, "missing", true, 100).collect() }
            delay(pause)
            job.cancel()
            val replacement = service.search(publication, file, "dictionary", true, 100).last()
            job.join()
            assertEquals(100, replacement.results.size)
            assertTrue(replacement.hasMore)
            assertFalse(replacement.indexing)
        }
    }

    @Test
    fun findsMatchesThroughoutLargeSingleResourceWithoutOverlapDuplicates() = runBlocking {
        val body = (1..1500).joinToString("") { "<p>Line $it ${"filler ".repeat(8)}boundary phrase tail.</p>" }
        val file = fixture(body)
        val publication = open(file)
        val result = service.search(publication, file, "boundary phrase", true, 1600).last()
        assertEquals(1500, result.results.size)
        assertEquals(1500, result.results.map { it.locations.progression }.toSet().size)
        assertTrue(result.results.all { it.text.highlight == "boundary phrase" })
        assertTrue(result.results.zipWithNext().all { (a, b) -> a.locations.progression!! < b.locations.progression!! })
    }

    @Test
    fun keepsHeadingOffsetsDistinctFromEarlierBodyMentions() = runBlocking {
        val file = fixture("<p>A dictionary mention.</p><h2>Dictionary</h2><p>The entry.</p>")
        val publication = open(file)
        val result = service.search(publication, file, "dictionary", true, 100).last()
        assertEquals(2, result.results.size)
        assertTrue(result.results.first().locations.progression!! > result.results.last().locations.progression!!)
        assertEquals("Dictionary", result.results.first().text.highlight)
    }

    @Test
    fun preservesSupplementaryCharactersAndWholeWordsAcrossChunkBoundaries() = runBlocking {
        val body = "a".repeat(3599) + "😀 tail " + "b".repeat(391) + "😀 marker " + "z".repeat(500)
        val file = fixture("<p>$body</p>")
        val publication = open(file)
        val symbols = service.search(publication, file, "😀", false, 100).last()
        assertEquals(2, symbols.results.size)
        assertTrue(symbols.results.all { it.text.highlight == "😀" })
        assertEquals(1, service.search(publication, file, "marker", true, 100).last().results.size)
        assertTrue(service.search(publication, file, "bbbb", true, 100).last().results.isEmpty())
    }

    @Test
    fun rebuildsCorruptDisposableIndex() = runBlocking {
        val file = fixture("<p>A needle remains searchable.</p>")
        val publication = open(file)
        service.search(publication, file, "needle", true, 100).last()
        val database = File(directory, "ebook-search-index").listFiles()!!.single { it.extension == "db" }
        database.writeText("corrupt test cache")
        assertEquals(1, service.search(publication, file, "needle", true, 100).last().results.size)
    }

    @Test
    fun benchmarksDictionaryWhenFixtureProvided() = runBlocking {
        val path = InstrumentationRegistry.getArguments().getString("searchDictionaryPath")
        assumeTrue(path != null)
        val stagingDirectory = File(Environment.getDataDirectory(), "local/tmp").canonicalFile
        val stagedFile = File(requireNotNull(path)).canonicalFile
        require(
            stagedFile.parentFile == stagingDirectory &&
                stagedFile.name.matches(Regex("[a-zA-Z0-9._-]+\\.epub")),
        )
        val file = File(directory, "dictionary.epub")
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("cat ${stagedFile.path}").use { descriptor ->
            FileInputStream(descriptor.fileDescriptor).use { input ->
                file.outputStream().use { input.copyTo(it) }
            }
        }
        val publication = open(file)
        val coldStart = SystemClock.elapsedRealtime()
        val cold = service.search(publication, file, "zzqnonexistentterm", true, 100).last()
        val coldMs = SystemClock.elapsedRealtime() - coldStart
        assertTrue(cold.results.isEmpty())
        val warmStart = SystemClock.elapsedRealtime()
        val warm = service.search(publication, file, "zzqnonexistentterm", true, 100).toList()
        val warmMs = SystemClock.elapsedRealtime() - warmStart
        assertTrue(warm.none { it.indexing })
        assertTrue(warm.last().results.isEmpty())
        val positiveStart = SystemClock.elapsedRealtime()
        val positive = service.search(publication, file, "Webster", true, 100).last()
        val positiveMs = SystemClock.elapsedRealtime() - positiveStart
        assertTrue(positive.results.isNotEmpty())
        Log.i("EbookSearchBenchmark", "coldMs=$coldMs warmNoResultMs=$warmMs warmPositiveMs=$positiveMs results=${positive.results.size}")
        Unit
    }

    private suspend fun open(file: File): Publication {
        val manager = ReadiumManager(context)
        val asset = manager.assetRetriever.retrieve(file).getOrElse { error(it.message) }
        return manager.publicationOpener.open(asset, allowUserInteraction = false)
            .getOrElse { error(it.message) }.also { opened += it }
    }

    private fun fixture(vararg sections: String, destination: File = File(directory, "${UUID.randomUUID()}.epub")): File {
        ZipOutputStream(destination.outputStream()).use { zip ->
            fun entry(name: String, content: String) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(content.toByteArray())
                zip.closeEntry()
            }
            entry("mimetype", "application/epub+zip")
            entry("META-INF/container.xml", """<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""")
            val manifest = sections.indices.joinToString("") { """<item id="c$it" href="chapter$it.xhtml" media-type="application/xhtml+xml"/>""" }
            val spine = sections.indices.joinToString("") { """<itemref idref="c$it"/>""" }
            entry("book.opf", """<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">test-search</dc:identifier><dc:title>Search Fixture</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-01-01T00:00:00Z</meta></metadata><manifest>$manifest</manifest><spine>$spine</spine></package>""")
            sections.forEachIndexed { index, body ->
                entry("chapter$index.xhtml", """<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Section $index</title></head><body>$body</body></html>""")
            }
        }
        return destination
    }
}
