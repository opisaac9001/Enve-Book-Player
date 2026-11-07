package com.enve.app.ui.screens

import android.graphics.Bitmap
import android.os.SystemClock
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.MainActivity
import com.enve.app.data.offline.ComicDownloadStatus
import com.enve.app.profiles.ProfileSwitchCoordinator
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ComicMetadata
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.UrlScheme
import java.io.File
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DownloadPillHubNavigationTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun tappingTheDownloadPillOpensTheHubShowingTheActiveComic() {
        val suffix = UUID.randomUUID().toString().take(8)
        val connectionId = "download-pill-$suffix"
        val bookId = "pill-issue-$suffix"
        val title = "Pill fixture $suffix"
        val server = StalledFileServer(bookId)
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var coordinator: ProfileSwitchCoordinator
            scenario.onActivity { coordinator = it.profiles }
            compose.waitUntil(20_000) { coordinator.activeRuntime.value != null }
            val component = coordinator.activeRuntime.value!!.component
            val downloads = component.comicDownloads()
            try {
                runBlocking {
                    component.connections().upsert(ProviderConnection(
                        id = connectionId, source = BookSource.KOMGA, name = "Download pill test",
                        serverUrl = "http://127.0.0.1:${server.port}", username = "", urlScheme = UrlScheme.HTTP,
                    ))
                    downloads.startDownload(Book(
                        id = bookId, title = title, source = BookSource.KOMGA, mediaType = AppMediaType.EBOOK,
                        connectionId = connectionId, primaryFileType = "cbz", comic = ComicMetadata(seriesId = "pill-series"),
                    ))
                    assertTrue(withContext(Dispatchers.IO) { server.transferStarted.await(20, TimeUnit.SECONDS) })
                    withTimeout(10_000) {
                        downloads.progressByBookId.first { it[bookId]?.status == ComicDownloadStatus.DOWNLOADING }
                    }
                }

                dismissPrompts()
                compose.waitUntil(10_000) { compose.onAllNodes(hasTestTag(PILL)).fetchSemanticsNodes().isNotEmpty() }
                compose.onNode(hasTestTag(PILL))
                    .assertIsDisplayed()
                    .assertHasClickAction()
                    .assert(hasContentDescription("Downloads"))
                    .assert(SemanticsMatcher("reports active items") {
                        it.config.getOrNull(SemanticsProperties.StateDescription)?.contains("item") == true
                    })
                screenshot("download-pill")
                compose.onNode(hasTestTag(PILL)).performClick()

                compose.waitUntil(10_000) { compose.onAllNodes(hasTestTag(PILL)).fetchSemanticsNodes().isEmpty() }
                compose.waitUntil(10_000) { compose.onAllNodes(hasText("Downloads")).fetchSemanticsNodes().isNotEmpty() }
                val hub = compose.onNode(hasScrollToNodeAction())
                compose.waitUntil(10_000) {
                    runCatching { hub.performScrollToNode(hasText(title)); true }.getOrDefault(false)
                }
                compose.onNodeWithText(title).assertIsDisplayed()
                screenshot("downloads-active-comic")
                hub.performScrollToNode(hasText("ACTIVE DOWNLOADS"))
                compose.onNodeWithText("ACTIVE DOWNLOADS").assertIsDisplayed()
                assertTrue(server.fileRequests.single().endsWith("/api/v1/books/$bookId/file"))
            } finally {
                downloads.cancelDownload(bookId)
                server.close()
                runBlocking {
                    withTimeoutOrNull(10_000) {
                        downloads.progressByBookId.first {
                            it[bookId]?.status != ComicDownloadStatus.DOWNLOADING && it[bookId]?.status != ComicDownloadStatus.QUEUED
                        }
                    }
                    downloads.removeDownload(bookId)
                    component.connections().remove(connectionId)
                }
            }
        }
    }

    private fun dismissPrompts() {
        if (compose.onAllNodes(hasText("Maybe later")).fetchSemanticsNodes().isNotEmpty()) {
            compose.onNodeWithText("Maybe later").performClick()
        }
    }

    private fun screenshot(name: String) {
        compose.waitForIdle()
        SystemClock.sleep(400)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: return
        val directory = File(instrumentation.targetContext.cacheDir, "parity-preview").apply { mkdirs() }
        File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    private class StalledFileServer(private val bookId: String) : AutoCloseable {
        private val socket = ServerSocket(0)
        private val clients = CopyOnWriteArrayList<Socket>()
        private val release = CountDownLatch(1)
        val port: Int get() = socket.localPort
        val transferStarted = CountDownLatch(1)
        val fileRequests = CopyOnWriteArrayList<String>()
        private val acceptor = thread(isDaemon = true, name = "download-pill-fixture") {
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                clients += client
                thread(isDaemon = true, name = "download-pill-client") { runCatching { serve(client) } }
            }
        }

        private fun serve(client: Socket) = client.use {
            val input = it.getInputStream().bufferedReader()
            val request = input.readLine() ?: return@use
            while (!input.readLine().isNullOrEmpty()) { }
            val method = request.substringBefore(' ')
            val path = request.substringAfter(' ').substringBefore(' ').substringBefore('?')
            val output = it.getOutputStream()
            if (method == "GET" && path == "/api/v1/books/$bookId/file") {
                fileRequests += path
                output.write("HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: $FILE_SIZE\r\nConnection: close\r\n\r\n".toByteArray())
                output.write(ByteArray(FIRST_CHUNK))
                output.flush()
                transferStarted.countDown()
                release.await(60, TimeUnit.SECONDS)
                return@use
            }
            val body = if (method == "GET") """{"content":[]}""".toByteArray() else byteArrayOf()
            output.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
            output.write(body)
            output.flush()
        }

        override fun close() {
            clients.forEach { client -> runCatching { client.setSoLinger(true, 0); client.close() } }
            release.countDown()
            socket.close()
            acceptor.join(2_000)
        }
    }

    private companion object {
        const val PILL = "download-progress-pill"
        const val FILE_SIZE = 8 * 1024 * 1024
        const val FIRST_CHUNK = 64 * 1024
    }
}
