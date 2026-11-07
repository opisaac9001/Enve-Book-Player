package com.enve.app.webimport

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicInteger

class WebStoryImportSessionTest {

    @get:Rule
    val folder = TemporaryFolder()

    private val server = MockWebServer()
    private val routes = HashMap<String, () -> MockResponse>()
    private lateinit var workDir: File
    private lateinit var importer: WebStoryImporter

    private val text = "The lamps along the harbour wall were lit one by one as the tide came in."

    @Before
    fun setUp() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                routes[request.path.orEmpty()]?.invoke() ?: MockResponse().setResponseCode(404)
        }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        importer = WebStoryImporter(WebPageFetcher.defaultClient(), WebStoryLimits(), requestSpacingMs = 0)
        workDir = File(folder.root, "session")
        routes["/index.html"] = {
            html(
                "<html><head><title>Harbour</title></head><body><ul id=\"chapters\">" +
                    "<li><a href=\"/chapter/21/\">Arrival</a></li><li><a href=\"/chapter/22/\">Departure</a></li></ul></body></html>",
            )
        }
        routes["/chapter/21/"] = { html("<html><body><article><p>Chapter 21. $text</p></article></body></html>") }
        routes["/chapter/22/"] = { html("<html><body><article><p>Chapter 22. $text</p></article></body></html>") }
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun stalePreviewNeverReplacesTheNewerOne() = runBlocking {
        val slowRequested = CompletableDeferred<Unit>()
        routes["/slow.html"] = {
            slowRequested.complete(Unit)
            MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE)
        }
        routes["/fast.html"] = { html("<html><head><title>Fast</title></head><body><article><p>$text</p></article></body></html>") }
        val session = WebStoryImportSession(this, importer, workDir)

        session.preview(local("/slow.html"))
        withTimeout(10_000) { slowRequested.await() }
        session.preview(local("/fast.html"))
        val ready = withTimeout(10_000) { session.state.first { it is WebStoryImportUiState.Ready } }
        assertEquals("Fast", (ready as WebStoryImportUiState.Ready).preview.metadata.title)
        delay(300)
        assertEquals(ready, session.state.value)
        session.close()
    }

    @Test
    fun cancellingAnImportDeletesThePartialBookAndNeverCommits() = runBlocking {
        val stalled = CompletableDeferred<Unit>()
        routes["/chapter/22/"] = {
            stalled.complete(Unit)
            MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE)
        }
        val commits = AtomicInteger()
        val session = WebStoryImportSession(this, importer, workDir)
        session.preview(local("/index.html"))
        awaitReady(session)

        session.import(WebStoryScope.WHOLE_STORY) { commits.incrementAndGet() }
        withTimeout(10_000) { stalled.await() }
        session.cancel()

        assertTrue(session.state.value is WebStoryImportUiState.Ready)
        withTimeout(10_000) { while (epubFiles().isNotEmpty()) delay(20) }
        delay(100)
        assertEquals(0, commits.get())
        assertTrue(session.state.value is WebStoryImportUiState.Ready)
        session.close()
    }

    @Test
    fun failingSelectedChapterReportsItAndLeavesNoArtifact() = runBlocking {
        routes["/chapter/22/"] = { MockResponse().setResponseCode(404) }
        val commits = AtomicInteger()
        val session = WebStoryImportSession(this, importer, workDir)
        session.preview(local("/index.html"))
        awaitReady(session)

        session.import(WebStoryScope.WHOLE_STORY) { commits.incrementAndGet() }
        val failed = withTimeout(10_000) {
            session.state.first { it is WebStoryImportUiState.Ready && it.error != null }
        } as WebStoryImportUiState.Ready
        assertTrue(failed.error!!.startsWith("Departure: "))
        assertEquals(0, commits.get())
        assertTrue(epubFiles().isEmpty())
        session.close()
    }

    @Test
    fun successfulImportCommitsOnceThenRemovesTemporaries() = runBlocking {
        val library = folder.newFolder("library")
        val session = WebStoryImportSession(this, importer, workDir)
        session.preview(local("/index.html"))
        awaitReady(session)

        session.import(WebStoryScope.WHOLE_STORY) { file -> file.copyTo(File(library, "book.epub")) }
        val saved = withTimeout(10_000) { session.state.first { it is WebStoryImportUiState.Saved } } as WebStoryImportUiState.Saved
        assertEquals(2, saved.chapters)
        assertTrue(epubEntries(File(library, "book.epub")).text("OEBPS/chapter-0002.xhtml").contains("Chapter 22."))
        assertTrue(workDir.walk().none { it.isFile })
        session.close()
    }

    @Test
    fun capturedPageIsPreviewedAndSavedWithoutNetwork() = runBlocking {
        val library = folder.newFolder("library")
        val session = WebStoryImportSession(this, importer, workDir)
        session.previewCaptured(local("/members/page"), "<html><head><title>Members</title></head><body><main><p>Signed-in text. $text</p></main></body></html>")
        val ready = awaitReady(session)
        assertTrue(ready.preview is WebStoryPreview.Page)

        session.import(WebStoryScope.WHOLE_STORY) { file -> file.copyTo(File(library, "page.epub")) }
        withTimeout(10_000) { session.state.first { it is WebStoryImportUiState.Saved } }
        assertTrue(epubEntries(File(library, "page.epub")).text("OEBPS/chapter-0001.xhtml").contains("Signed-in text."))
        assertEquals(0, server.requestCount)
        session.close()
    }

    @Test
    fun closingDeletesDownloadedFilesAndCancelsWork() = runBlocking {
        routes["/book.epub"] = {
            MockResponse().setHeader("Content-Type", "application/epub+zip")
                .setBody(Buffer().write(byteArrayOf(0x50, 0x4B, 0x03, 0x04) + ByteArray(32)))
        }
        val session = WebStoryImportSession(this, importer, workDir)
        session.preview(local("/book.epub"))
        val preview = awaitReady(session).preview as WebStoryPreview.Download
        assertTrue(preview.file.exists())

        session.close()
        assertFalse(preview.file.exists())
        assertFalse(workDir.exists())
    }

    private suspend fun awaitReady(session: WebStoryImportSession): WebStoryImportUiState.Ready =
        withTimeout(10_000) { session.state.first { it is WebStoryImportUiState.Ready } } as WebStoryImportUiState.Ready

    private fun epubFiles() = workDir.walk().filter { it.isFile && it.name.endsWith(".epub") }.toList()

    private fun local(path: String) = "http://127.0.0.1:${server.port}$path"

    private fun html(body: String) = MockResponse().setHeader("Content-Type", "text/html; charset=utf-8").setBody(body)
}
