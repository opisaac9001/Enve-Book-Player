package com.enve.app.data.fileimport

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class DropboxLinkDownloaderTest {
    @get:Rule val folder = TemporaryFolder()
    private val server = MockWebServer()
    private lateinit var work: File
    private lateinit var downloader: DropboxLinkDownloader

    private val pdfLink = DropboxSharedLink.parse("https://www.dropbox.com/scl/fi/shareid123/Manual.pdf?rlkey=SECRETKEY&dl=0")
    private val signedLocation = "https://uc1a2b.dl.dropboxusercontent.com/cd/0/get/SIGNEDTOKEN/file?_download_id=7"

    @Before
    fun setUp() {
        server.start()
        work = File(folder.root, "dropbox-links")
        val routed = OkHttpClient.Builder().addInterceptor { chain ->
            val logical = chain.request().url
            val target = server.url(logical.encodedPath).newBuilder().encodedQuery(logical.encodedQuery).build()
            chain.proceed(chain.request().newBuilder().url(target).header("X-Logical-Host", logical.host).build())
        }.build()
        downloader = DropboxLinkDownloader(routed, work)
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun redirect(location: String) = MockResponse().setResponseCode(302).setHeader("Location", location)

    private fun file(body: String, type: String = "application/pdf") =
        MockResponse().setResponseCode(200).setHeader("Content-Type", type).setBody(body)

    private fun failure(link: DropboxSharedLink = pdfLink): String = runBlocking {
        try {
            downloader.download(link)
        } catch (expected: IOException) {
            val message = expected.message.orEmpty()
            listOf("SECRETKEY", "SIGNEDTOKEN", "shareid123", "dropboxusercontent").forEach { assertFalse(message.contains(it)) }
            return@runBlocking message
        }
        fail("Expected the download to fail")
        error("unreachable")
    }

    private fun workFiles(): List<String> = work.list()?.toList().orEmpty()

    @Test
    fun followsTrustedRedirectsWithoutCredentials() = runBlocking {
        server.enqueue(redirect(signedLocation))
        server.enqueue(file("%PDF-1.7 body"))

        val downloaded = downloader.download(pdfLink)

        assertEquals("%PDF-1.7 body", downloaded.readText())
        val first = server.takeRequest()
        val second = server.takeRequest()
        assertEquals("www.dropbox.com", first.getHeader("X-Logical-Host"))
        assertEquals("/scl/fi/shareid123/Manual.pdf", first.requestUrl!!.encodedPath)
        assertEquals("1", first.requestUrl!!.queryParameter("dl"))
        assertEquals("SECRETKEY", first.requestUrl!!.queryParameter("rlkey"))
        assertEquals("uc1a2b.dl.dropboxusercontent.com", second.getHeader("X-Logical-Host"))
        assertEquals("/cd/0/get/SIGNEDTOKEN/file", second.requestUrl!!.encodedPath)
        listOf(first, second).forEach { request ->
            assertNull(request.getHeader("Authorization"))
            assertNull(request.getHeader("Cookie"))
        }
        assertEquals(work, downloaded.parentFile)
        listOf("SECRETKEY", "SIGNEDTOKEN", "shareid123", "Manual").forEach { assertFalse(downloaded.name.contains(it)) }
    }

    @Test
    fun ignoresCookiesSetDuringRedirects() = runBlocking {
        server.enqueue(redirect(signedLocation).addHeader("Set-Cookie", "session=abc; Domain=dropboxusercontent.com"))
        server.enqueue(file("%PDF-1.7"))

        downloader.download(pdfLink)

        server.takeRequest()
        assertNull(server.takeRequest().getHeader("Cookie"))
    }

    @Test
    fun stopsAtRedirectsToUntrustedHosts() {
        listOf(
            "https://dropboxusercontent.com.evil.test/x",
            "https://evildropbox.com/x",
            "http://uc1.dl.dropboxusercontent.com/x",
            "https://user@uc1.dl.dropboxusercontent.com/x",
            "https://uc1.dl.dropboxusercontent.com:8443/x",
            "https://127.0.0.1/x",
        ).forEach { location ->
            server.enqueue(redirect(location))
            assertEquals(DropboxLinkDownloader.UNTRUSTED_REDIRECT, failure())
        }
        assertEquals(6, server.requestCount)
        assertTrue(workFiles().isEmpty())
    }

    @Test
    fun rejectsRedirectsWithoutALocation() {
        server.enqueue(MockResponse().setResponseCode(302))

        assertEquals(DropboxLinkDownloader.UNTRUSTED_REDIRECT, failure())
    }

    @Test
    fun boundsTheRedirectChain() {
        repeat(6) { server.enqueue(redirect("https://www.dropbox.com/scl/fi/shareid123/Manual.pdf?dl=1")) }

        assertEquals(DropboxLinkDownloader.TOO_MANY_REDIRECTS, failure())
        assertEquals(6, server.requestCount)
    }

    @Test
    fun rejectsLoginAndErrorPages() {
        server.enqueue(file("<html>Sign in</html>", type = "text/html; charset=utf-8"))
        assertEquals(DropboxLinkDownloader.NOT_A_FILE, failure())

        server.enqueue(file("﻿  <!DOCTYPE html><html></html>", type = "application/octet-stream"))
        assertEquals(DropboxLinkDownloader.NOT_A_FILE, failure())

        server.enqueue(MockResponse().setResponseCode(404).setBody("missing"))
        assertEquals(DropboxLinkDownloader.UNAVAILABLE, failure())

        server.enqueue(MockResponse().setResponseCode(500))
        assertEquals("Dropbox couldn't send the file (HTTP 500).", failure())

        assertTrue(workFiles().isEmpty())
    }

    @Test
    fun rejectsFolderArchivesAndMismatchedFiles() {
        server.enqueue(file("%PDF").setHeader("Content-Disposition", "attachment; filename=\"Shared Folder.zip\""))
        assertEquals(DropboxLinkDownloader.DIFFERENT_FILE, failure())

        server.enqueue(MockResponse().setBody(Buffer().write(byteArrayOf(0x50, 0x4b, 0x03, 0x04, 0x14))).setHeader("Content-Type", "application/zip"))
        assertEquals(DropboxLinkDownloader.DIFFERENT_FILE, failure())

        assertTrue(workFiles().isEmpty())
    }

    @Test
    fun acceptsZipContainersNamedByTheLink() = runBlocking {
        val epub = DropboxSharedLink.parse("https://www.dropbox.com/s/shareid123/Story.epub")
        server.enqueue(
            MockResponse().setBody(Buffer().write(byteArrayOf(0x50, 0x4b, 0x03, 0x04, 0x14)))
                .setHeader("Content-Disposition", "attachment; filename=\"Story.epub\"; filename*=UTF-8''Story.epub"),
        )

        assertEquals(5L, downloader.download(epub).length())
    }

    @Test
    fun rejectsTruncatedDownloads() {
        server.enqueue(file("%PDF-" + "x".repeat(64 * 1_024)).setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY))

        assertEquals(DropboxLinkDownloader.INTERRUPTED, failure())
        assertTrue(workFiles().isEmpty())
    }

    @Test
    fun rejectsEmptyBodies() {
        server.enqueue(file(""))

        assertEquals(DropboxLinkDownloader.NOT_A_FILE, failure())
    }

    @Test
    fun cancellationStopsTheTransferAndCleansUp() = runBlocking {
        val started = CountDownLatch(1)
        server.enqueue(file("%PDF-" + "x".repeat(1_024)).throttleBody(1, 1, TimeUnit.SECONDS))
        val job = async(Dispatchers.Default) { downloader.download(pdfLink) { started.countDown() } }

        assertTrue(started.await(5, TimeUnit.SECONDS))
        withTimeout(5_000) { job.cancelAndJoin() }

        assertTrue(job.isCancelled)
        assertTrue(workFiles().isEmpty())
    }

    @Test
    fun removesOnlyStalePartialFiles() = runBlocking {
        work.mkdirs()
        val stale = File(work, "old.part").apply { writeText("x"); setLastModified(System.currentTimeMillis() - 7 * 60 * 60 * 1_000L) }
        val fresh = File(work, "fresh.part").apply { writeText("y") }
        server.enqueue(file("%PDF"))

        downloader.download(pdfLink)

        assertFalse(stale.exists())
        assertTrue(fresh.exists())
    }

    @Test
    fun trustsOnlyDropboxOwnedHttpsHosts() {
        listOf(
            "https://www.dropbox.com/x",
            "https://dropbox.com/x",
            "https://dl.dropbox.com/x",
            "https://uc1.dl.dropboxusercontent.com/x",
        ).forEach { assertTrue(it, DropboxLinkDownloader.isTrustedRedirect(it.toHttpUrl())) }
        listOf(
            "http://www.dropbox.com/x",
            "https://dropbox.com.evil.test/x",
            "https://notdropbox.com/x",
            "https://dropboxusercontent.co/x",
            "https://a:b@www.dropbox.com/x",
            "https://www.dropbox.com:444/x",
            "https://www.dropbox.com/x#frag",
        ).forEach { assertFalse(it, DropboxLinkDownloader.isTrustedRedirect(it.toHttpUrl())) }
    }

    @Test
    fun readsServedFileNames() {
        assertEquals("A b.epub", DropboxLinkDownloader.servedFileName("attachment; filename=\"a.epub\"; filename*=UTF-8''A%20b.epub"))
        assertEquals("Folder.zip", DropboxLinkDownloader.servedFileName("attachment; filename=\"Folder.zip\""))
        assertEquals("plain.mp3", DropboxLinkDownloader.servedFileName("attachment; filename=plain.mp3"))
        assertNull(DropboxLinkDownloader.servedFileName("inline"))
        assertNull(DropboxLinkDownloader.servedFileName(null))
    }
}
