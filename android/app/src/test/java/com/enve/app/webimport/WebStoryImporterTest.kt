package com.enve.app.webimport

import com.enve.app.webimport.WebStoryImportException.Reason
import kotlinx.coroutines.runBlocking
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import okio.GzipSink
import okio.buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.net.InetAddress
import java.util.Collections

class WebStoryImporterTest {

    @get:Rule
    val folder = TemporaryFolder()

    private val loopback = InetAddress.getByName("127.0.0.1")
    private val server = MockWebServer()
    private val routes = HashMap<String, () -> MockResponse>()
    private val requested: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private lateinit var client: OkHttpClient
    private lateinit var workDir: File

    private val text = "The caravan crossed the salt flats at dawn, and every wheel left a pale scar behind it."

    @Before
    fun setUp() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path.orEmpty()
                requested += path
                return routes[path]?.invoke() ?: MockResponse().setResponseCode(404)
            }
        }
        server.start(loopback, 0)
        client = WebPageFetcher.defaultClient().newBuilder()
            .dns(object : Dns {
                override fun lookup(hostname: String) = listOf(loopback)
            })
            .build()
        workDir = folder.newFolder("work")
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun importer(limits: WebStoryLimits = WebStoryLimits()) = WebStoryImporter(client, limits, requestSpacingMs = 0)

    @Test
    fun genericFixtureIndexImportsWholeStory() = runBlocking {
        serveGenericStory()
        val preview = importer().preview(local("/index.html"), workDir) as WebStoryPreview.Serial
        assertEquals("Salt Roads", preview.metadata.title)
        assertEquals(listOf("Arrival", "Departure"), preview.chapters.map { it.title })
        assertNull(preview.currentIndex)
        assertEquals(listOf(WebStoryScope.WHOLE_STORY), preview.scopes)

        val result = importer().import(preview, WebStoryScope.WHOLE_STORY, workDir) {}
        assertEquals(2, result.chapters)
        val entries = epubEntries(result.file)
        val first = entries.text("OEBPS/chapter-0001.xhtml")
        parseXml(first)
        assertTrue(first.contains("Text of chapter 21."))
        assertTrue(first.contains("href=\"${local("/chapter/21/")}\""))
        assertTrue(entries.text("OEBPS/chapter-0002.xhtml").contains("Text of chapter 22."))
        assertTrue(entries.text("OEBPS/content.opf").contains("<dc:source>${local("/index.html")}</dc:source>"))
        assertFalse(requested.any { it.contains("23") || it.contains("about") })
    }

    @Test
    fun chapterLinkUsesParentIndexAndDoesNotRefetchThatChapter() = runBlocking {
        serveGenericStory()
        val preview = importer().preview(local("/chapter/22/"), workDir) as WebStoryPreview.Serial
        assertEquals(1, preview.currentIndex)
        assertEquals(listOf(WebStoryScope.THIS_CHAPTER, WebStoryScope.FROM_HERE, WebStoryScope.WHOLE_STORY), preview.scopes)
        assertEquals(WebStoryScope.THIS_CHAPTER, preview.defaultScope)

        val result = importer().import(preview, WebStoryScope.THIS_CHAPTER, workDir) {}
        assertEquals(1, result.chapters)
        assertTrue(epubEntries(result.file).text("OEBPS/chapter-0001.xhtml").contains("Text of chapter 22."))
        assertEquals(1, requested.count { it == "/chapter/22/" })
        assertFalse(requested.contains("/chapter/21/"))
    }

    @Test
    fun chapterMissingFromParentIndexIsNotGuessed() {
        serveGenericStory()
        routes["/chapter/40/"] = { html(chapterPage(40)) }
        expectReason(Reason.CHAPTER_NOT_IN_INDEX) { importer().preview(local("/chapter/40/"), workDir) }
    }

    @Test
    fun chapterWithoutParentIndexImportsOnlyThatPage() = runBlocking {
        routes["/chapter/7/"] = { html("<html><body><article><p>Lonely chapter. $text</p></article></body></html>") }
        val preview = importer().preview(local("/chapter/7/"), workDir)
        assertTrue(preview is WebStoryPreview.Page)
    }

    @Test
    fun paginatedIndexIsCollectedCompletelyAndDeduplicated() = runBlocking {
        routes["/index.html"] = { html(indexPage(listOf(21, 22), next = "/index.html?page=2")) }
        routes["/index.html?page=2"] = { html(indexPage(listOf(22, 23), next = "/index.html?page=3")) }
        routes["/index.html?page=3"] = { html(indexPage(listOf(24), next = null)) }
        val preview = importer().preview(local("/index.html"), workDir) as WebStoryPreview.Serial
        assertEquals(listOf("21", "22", "23", "24"), preview.chapters.map { WebStoryUrls.chapterId(it.url) })
    }

    @Test
    fun indexPaginationLoopsOffOriginLinksFailuresAndCapsStopThePreview() {
        routes["/loop.html"] = { html(indexPage(listOf(1), next = "/loop2.html")) }
        routes["/loop2.html"] = { html(indexPage(listOf(2), next = "/loop.html")) }
        expectReason(Reason.INDEX_INCOMPLETE) { importer().preview(local("/loop.html"), workDir) }

        routes["/offsite.html"] = { html(indexPage(listOf(1), next = "http://elsewhere.example:${server.port}/page2")) }
        expectReason(Reason.INDEX_INCOMPLETE) { importer().preview(local("/offsite.html"), workDir) }
        assertFalse(requested.contains("/page2"))

        routes["/broken.html"] = { html(indexPage(listOf(1), next = "/broken2.html")) }
        routes["/broken2.html"] = { MockResponse().setResponseCode(500) }
        expectReason(Reason.SERVER_ERROR) { importer().preview(local("/broken.html"), workDir) }

        (1..4).forEach { page -> routes["/many.html?p=$page"] = { html(indexPage(listOf(page), next = "/many.html?p=${page + 1}")) } }
        expectReason(Reason.STORY_TOO_LARGE) { importer(WebStoryLimits(maxIndexPages = 3)).preview(local("/many.html?p=1"), workDir) }

        routes["/wide.html"] = { html(indexPage((1..5).toList(), next = null)) }
        expectReason(Reason.STORY_TOO_LARGE) { importer(WebStoryLimits(maxChapters = 4)).preview(local("/wide.html"), workDir) }
    }

    @Test
    fun selectedChapterFailureFailsTheWholeImportWithoutAnArtifact() = runBlocking {
        serveGenericStory()
        routes["/chapter/22/"] = { MockResponse().setResponseCode(403) }
        val preview = importer().preview(local("/index.html"), workDir) as WebStoryPreview.Serial
        val error = assertThrows(WebStoryImportException::class.java) {
            runBlocking { importer().import(preview, WebStoryScope.WHOLE_STORY, workDir) {} }
        }
        assertEquals(Reason.ACCESS_DENIED, error.reason)
        assertEquals("Departure", error.chapterTitle)
        assertTrue(workDir.walk().none { it.isFile })
    }

    @Test
    fun emptyChapterAndOffOriginRedirectFailTheImport() = runBlocking {
        serveGenericStory()
        routes["/chapter/21/"] = { html("<html><body><nav>Menu only</nav></body></html>") }
        val preview = importer().preview(local("/index.html"), workDir) as WebStoryPreview.Serial
        expectReason(Reason.NO_CONTENT) { importer().import(preview, WebStoryScope.WHOLE_STORY, workDir) {} }

        routes["/chapter/21/"] = { MockResponse().setResponseCode(302).setHeader("Location", "http://elsewhere.example:${server.port}/chapter/21/") }
        expectReason(Reason.OFF_ORIGIN) { importer().import(preview, WebStoryScope.WHOLE_STORY, workDir) {} }
        assertTrue(workDir.walk().none { it.isFile })
    }

    @Test
    fun responseAndByteBudgetsStopLongImports() = runBlocking {
        serveGenericStory()
        val preview = importer().preview(local("/index.html"), workDir) as WebStoryPreview.Serial
        expectReason(Reason.STORY_TOO_LARGE) { importer(WebStoryLimits(maxResponses = 1)).import(preview, WebStoryScope.WHOLE_STORY, workDir) {} }
        expectReason(Reason.STORY_TOO_LARGE) { importer(WebStoryLimits(maxTotalBytes = 300)).import(preview, WebStoryScope.WHOLE_STORY, workDir) {} }
        expectReason(Reason.TOO_LARGE) { importer(WebStoryLimits(maxPageBytes = 64)).import(preview, WebStoryScope.WHOLE_STORY, workDir) {} }
        assertTrue(workDir.walk().none { it.isFile })
    }

    @Test
    fun royalRoadChapterLinkFindsItsFictionAndImportsFromHere() = runBlocking {
        val chapters = (1..3).map { "/fiction/77/the-long-road/chapter/${1000 + it}/c$it" }
        routes["/fiction/77"] = {
            html(
                """
                <html lang="en"><head><meta property="books:author" content="A. Writer"></head><body>
                <div class="fic-title"><h1>The Long Road</h1></div>
                <table id="chapters"><tbody>
                ${chapters.mapIndexed { i, path -> "<tr class=\"chapter-row\"><td><a href=\"$path\">Chapter ${i + 1}</a></td></tr>" }.joinToString("")}
                <tr class="chapter-row"><td><a href="/fiction/78/x/chapter/9/other">Other</a></td></tr>
                </tbody></table></body></html>
                """,
            )
        }
        chapters.forEachIndexed { i, path ->
            routes[path] = {
                html(
                    """
                    <html><head><style>.cmX1{display:none;}</style></head><body>
                    <div class="author-note-portlet">Author note</div>
                    <div class="chapter-inner chapter-content"><p>Text of RR chapter ${i + 1}.</p><p class="cmX1">Stolen notice</p></div>
                    </body></html>
                    """,
                )
            }
        }
        val preview = importer().preview("http://www.royalroad.com:${server.port}${chapters[1]}", workDir) as WebStoryPreview.Serial
        assertEquals(3, preview.chapters.size)
        assertEquals(1, preview.currentIndex)
        assertNull(preview.currentPage)

        val result = importer().import(preview, WebStoryScope.FROM_HERE, workDir) {}
        val entries = epubEntries(result.file)
        assertEquals(2, result.chapters)
        assertTrue(entries.text("OEBPS/content.opf").contains("<dc:creator id=\"creator\">A. Writer</dc:creator>"))
        val chapter = entries.text("OEBPS/chapter-0001.xhtml")
        assertTrue(chapter.contains("Text of RR chapter 2."))
        assertFalse(chapter.contains("Stolen notice"))
        assertFalse(chapter.contains("Author note"))
        assertFalse(requested.contains(chapters[0]))
    }

    @Test
    fun plainTextBecomesAnEpub() = runBlocking {
        routes["/notes/story.txt"] = {
            MockResponse().setHeader("Content-Type", "text/plain; charset=utf-8").setBody("First line\nsecond <line>\n\nNext paragraph & more")
        }
        val preview = importer().preview(local("/notes/story.txt"), workDir) as WebStoryPreview.Page
        assertEquals("story", preview.metadata.title)
        val chapter = epubEntries(importer().import(preview, WebStoryScope.WHOLE_STORY, workDir) {}.file).text("OEBPS/chapter-0001.xhtml")
        parseXml(chapter)
        assertTrue(chapter.contains("<p>First line<br />second &lt;line&gt;</p><p>Next paragraph &amp; more</p>"))
    }

    @Test
    fun directEbookLinksAreDownloadedWithAVerifiedExtension() = runBlocking {
        val epub = byteArrayOf(0x50, 0x4B, 0x03, 0x04) + ByteArray(64) { 7 }
        routes["/books/novel.epub"] = { MockResponse().setHeader("Content-Type", "application/octet-stream").setBody(Buffer().write(epub)) }
        routes["/books/fake.epub"] = { MockResponse().setHeader("Content-Type", "application/epub+zip").setBody("<html>not a book</html>") }
        routes["/books/huge.pdf"] = { MockResponse().setHeader("Content-Type", "application/pdf").setBody(Buffer().write(ByteArray(2048))) }
        routes["/audio.mp3"] = { MockResponse().setHeader("Content-Type", "audio/mpeg").setBody("ID3") }

        val preview = importer().preview(local("/books/novel.epub"), workDir) as WebStoryPreview.Download
        assertEquals(WebStoryFileFormat.EPUB, preview.format)
        assertEquals("novel.epub", preview.file.name)
        assertArrayEquals(epub, preview.file.readBytes())
        preview.file.delete()

        expectReason(Reason.UNSUPPORTED) { importer().preview(local("/books/fake.epub"), workDir) }
        expectReason(Reason.TOO_LARGE) { importer(WebStoryLimits(maxDownloadBytes = 1024)).preview(local("/books/huge.pdf"), workDir) }
        expectReason(Reason.UNSUPPORTED) { importer().preview(local("/audio.mp3"), workDir) }
        assertTrue(workDir.walk().none { it.isFile })
    }

    @Test
    fun capturedChapterTablePreservesItsOrderWithoutRefetchingTheIndex() = runBlocking {
        val html = """<h1>Willow walk</h1><div id="chapters"><a href="/chapter/21">Orchard</a><a href="/chapter/22">River</a></div>"""
        val preview = importer().previewCaptured(local("/walk"), html) as WebStoryPreview.Serial
        assertEquals(listOf("Orchard", "River"), preview.chapters.map { it.title })
        assertTrue(requested.isEmpty())
    }

    @Test
    fun aScriptOnlyNextPageCannotBecomeAPartialBook() = runBlocking {
        val html = """<section><div id="chapters"><a href="/chapter/21">Orchard</a></div>
            <ul class="pagination-small"><li class="nav-arrow"><a href="#"><span class="fa-chevron-right"></span></a></li></ul></section>"""
        expectReason(Reason.INTERACTIVE_INDEX) { importer().previewCaptured(local("/walk"), html) }
        assertTrue(requested.isEmpty())
    }

    @Test
    fun capturedPageIsImportedWithoutNetwork() = runBlocking {
        val captured = "<html><head><title>Members only</title></head><body><article><p>Rendered text. $text</p>" +
            "<img src=\"https://cdn.example/x.png\" alt=\"A lighthouse\"><script>steal()</script></article></body></html>"
        val preview = importer().previewCaptured(local("/members/story"), captured) as WebStoryPreview.Page
        val chapter = epubEntries(importer().import(preview, WebStoryScope.WHOLE_STORY, workDir) {}.file).text("OEBPS/chapter-0001.xhtml")
        assertTrue(chapter.contains("Rendered text."))
        assertTrue(chapter.contains("A lighthouse"))
        assertFalse(chapter.contains("steal()"))
        assertEquals(0, server.requestCount)
        expectReason(Reason.INVALID_URL) { importer().previewCaptured("about:blank", captured) }
        expectReason(Reason.TOO_LARGE) { importer(WebStoryLimits(maxPageBytes = 10)).previewCaptured(local("/x"), captured) }
    }

    @Test
    fun decompressedBytesAreBounded() {
        val gzipped = Buffer()
        GzipSink(gzipped).buffer().use { it.writeUtf8("<html><body><p>" + "a".repeat(200_000) + "</p></body></html>") }
        routes["/bomb.html"] = {
            MockResponse().setHeader("Content-Type", "text/html").setHeader("Content-Encoding", "gzip").setBody(gzipped.clone())
        }
        expectReason(Reason.TOO_LARGE) { importer(WebStoryLimits(maxPageBytes = 50_000)).preview(local("/bomb.html"), workDir) }
    }

    @Test
    fun httpFailuresMapToReasons() {
        routes["/denied"] = { MockResponse().setResponseCode(403) }
        routes["/challenge"] = { MockResponse().setResponseCode(403).setHeader("cf-mitigated", "challenge") }
        routes["/missing"] = { MockResponse().setResponseCode(410) }
        routes["/limited"] = { MockResponse().setResponseCode(429) }
        routes["/loop"] = { MockResponse().setResponseCode(302).setHeader("Location", "/loop") }
        routes["/empty"] = { html("<html><body><nav>Only navigation</nav></body></html>") }
        expectReason(Reason.ACCESS_DENIED) { importer().preview(local("/denied"), workDir) }
        expectReason(Reason.BROWSER_CHECK) { importer().preview(local("/challenge"), workDir) }
        expectReason(Reason.NOT_FOUND) { importer().preview(local("/missing"), workDir) }
        expectReason(Reason.RATE_LIMITED) { importer().preview(local("/limited"), workDir) }
        expectReason(Reason.SERVER_ERROR) { importer().preview(local("/loop"), workDir) }
        expectReason(Reason.NO_CONTENT) { importer().preview(local("/empty"), workDir) }
        expectReason(Reason.INVALID_URL) { importer().preview("127.0.0.1/index.html", workDir) }
    }

    private fun serveGenericStory() {
        routes["/index.html"] = { html(indexPage(listOf(21, 22), next = null)) }
        routes["/chapter/21/"] = { html(chapterPage(21)) }
        routes["/chapter/22/"] = { html(chapterPage(22)) }
    }

    private fun indexPage(ids: List<Int>, next: String?) = """
        <html lang="en"><head><title>Salt Roads</title>${next?.let { "<link rel=\"next\" href=\"$it\">" }.orEmpty()}</head>
        <body><h1>Salt Roads</h1><ul id="chapters">
        ${ids.joinToString("") { "<li><a href=\"/chapter/$it/\">${if (it == 21) "Arrival" else if (it == 22) "Departure" else "Part $it"}</a></li>" }}
        <li><a href="http://evil.example/chapter/23/">Elsewhere</a></li>
        </ul><a href="/about">About</a></body></html>
    """

    private fun chapterPage(id: Int) = """
        <html><head><link rel="index" href="/index.html"></head>
        <body><nav>Site menu</nav><article><h1>Chapter $id</h1><p>Text of chapter $id. $text</p>
        <img src="/art.png" alt=""></article></body></html>
    """

    private fun local(path: String) = "http://127.0.0.1:${server.port}$path"

    private fun html(body: String) = MockResponse()
        .setHeader("Content-Type", "text/html; charset=utf-8")
        .setBody(body.trimIndent())

    private fun expectReason(reason: Reason, block: suspend () -> Unit) {
        val error = assertThrows(WebStoryImportException::class.java) { runBlocking { block() } }
        assertEquals(error.displayMessage, reason, error.reason)
    }
}
