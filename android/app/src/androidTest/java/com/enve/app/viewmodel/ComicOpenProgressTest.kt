package com.enve.app.viewmodel

import android.content.Context
import android.graphics.Bitmap
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.playback.AndroidAutoDebugEntryPoint
import com.enve.app.ui.screens.ReaderFormat
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.UrlScheme
import dagger.hilt.android.EntryPointAccessors
import java.io.ByteArrayOutputStream
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ComicOpenProgressTest {
    @Test
    fun openingAComicPushesNothingUntilTheReaderMoves() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val profiles = EntryPointAccessors.fromApplication(context, AndroidAutoDebugEntryPoint::class.java)
            .profileCoordinator()
        profiles.initialize()
        val component = checkNotNull(profiles.activeRuntime.value).component
        val connectionId = "comic-open-${UUID.randomUUID()}"
        val viewModels = ViewModelStore()
        val server = FixtureServer()
        try {
            component.connections().upsert(ProviderConnection(
                id = connectionId, source = BookSource.KOMGA, name = "Open progress test",
                serverUrl = "http://127.0.0.1:${server.port}", username = "", urlScheme = UrlScheme.HTTP,
            ))
            val reader = withContext(Dispatchers.Main) {
                ComicReaderViewModel(
                    context, component.preferences(), component.grimmoryRepository(), component.aggregator(),
                    component.annotationRepository(), component.komgaRepository(), component.comicDownloads(),
                    component.bookCacheDao(), component.serverPageStreamingService(),
                    component.comicReadingDirectionOverrideStore(), component.storageLocations(), component.database(),
                ).also {
                    viewModels.put("reader", it)
                    it.initialize(ComicReaderArgs(
                        bookId = "issue", bookSource = BookSource.KOMGA, connectionId = connectionId,
                        title = "Progress fixture", author = "Enve", format = ReaderFormat.CBZ, locator = null,
                    ))
                }
            }
            val loaded = withTimeout(20_000) { reader.state.first { !it.isLoading } }
            assertNull(loaded.error)
            assertEquals(1, loaded.currentPage)

            withContext(Dispatchers.Main) { reader.syncProgress() }
            delay(1_500)
            assertTrue("Opening must not push progress: ${server.progressBodies}", server.progressBodies.isEmpty())

            withContext(Dispatchers.Main) { reader.showPage(loaded.pages.lastIndex) }
            withTimeout(10_000) { while (server.progressBodies.isEmpty()) delay(50) }
            assertTrue(server.progressBodies.single().contains("\"completed\":true"))
        } finally {
            withContext(Dispatchers.Main) { viewModels.clear() }
            component.connections().remove(connectionId)
            server.close()
        }
    }

    private class FixtureServer : AutoCloseable {
        private val socket = ServerSocket(0)
        val port: Int get() = socket.localPort
        val progressBodies = CopyOnWriteArrayList<String>()
        private val page = ByteArrayOutputStream().also { output ->
            Bitmap.createBitmap(200, 300, Bitmap.Config.ARGB_8888).also {
                it.eraseColor(android.graphics.Color.WHITE)
                it.compress(Bitmap.CompressFormat.PNG, 100, output)
                it.recycle()
            }
        }.toByteArray()
        private val worker = thread(isDaemon = true, name = "komga-open-progress-fixture") {
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                client.use {
                    val input = it.getInputStream().bufferedReader()
                    val request = input.readLine() ?: return@use
                    var contentLength = 0
                    while (true) {
                        val header = input.readLine()
                        if (header.isNullOrEmpty()) break
                        if (header.startsWith("Content-Length:", ignoreCase = true)) {
                            contentLength = header.substringAfter(':').trim().toInt()
                        }
                    }
                    val method = request.substringBefore(' ')
                    val path = request.substringAfter(' ').substringBefore(' ').substringBefore('?')
                    if (method == "PATCH" && path.endsWith("/read-progress")) {
                        progressBodies += String(CharArray(contentLength).also { chars -> input.read(chars) })
                    }
                    val body = when {
                        method != "GET" -> byteArrayOf()
                        path.endsWith("/pages") -> """[{"number":1,"fileName":"1.png","mediaType":"image/png"},{"number":2,"fileName":"2.png","mediaType":"image/png"},{"number":3,"fileName":"3.png","mediaType":"image/png"}]""".toByteArray()
                        path.contains("/pages/") -> page
                        path.endsWith("/series/ltr") -> """{"id":"ltr","libraryId":"comics","name":"Comics","metadata":{"readingDirection":"LEFT_TO_RIGHT"}}""".toByteArray()
                        path.endsWith("/books/issue") -> """{"id":"issue","seriesId":"ltr","seriesTitle":"Comics","libraryId":"comics","name":"issue.cbz","media":{"status":"READY","mediaType":"application/zip","mediaProfile":"DIVINA","pagesCount":3},"readProgress":{"page":2,"completed":false}}""".toByteArray()
                        else -> """{"content":[]}""".toByteArray()
                    }
                    val type = if (path.contains("/pages/")) "image/png" else "application/json"
                    val output = it.getOutputStream()
                    output.write("HTTP/1.1 200 OK\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
                    output.write(body)
                    output.flush()
                }
            }
        }

        override fun close() {
            socket.close()
            worker.join(2_000)
        }
    }
}
