package com.enve.app.data.local

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.sync.GrimmoryAudiobookSyncStrategy
import com.enve.app.profiles.ProfileRuntimeRegistry
import com.enve.core.data.local.PendingProgressPush
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.UrlScheme
import com.enve.core.data.remote.ConnectionScope
import java.net.ServerSocket
import java.util.UUID
import kotlin.concurrent.thread
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PublicSourceRegressionTest {
    @Test
    fun reopeningStreamedComicWaitsForItsPendingCleanup() = runBlocking {
        withProfile { component ->
            val pages = component.serverPageStreamingService()
            repeat(20) {
                val old = pages.openSession("reopen-fixture", 1)
                pages.ensurePage(old, 0) { _, destination -> destination.writeBytes(ByteArray(256)) }
                pages.clear(old)
                pages.clear(old)
                val reopened = pages.openSession("reopen-fixture", 1)
                val page = pages.ensurePage(reopened, 0) { _, destination -> destination.writeBytes(ByteArray(256)) }
                assertEquals(setOf(0), pages.cachedPageIndices(reopened))
                assertEquals(256L, page.length())
            }
        }
    }

    @Test
    fun sameBookIdOnTwoServersKeepsProgressAndNarratorsSeparate() = runBlocking {
        withProfile { component ->
            component.serverSync().setEnabled(true)
            val servers = listOf(ProgressServer(80), ProgressServer(40))
            try {
                val books = servers.mapIndexed { index, server ->
                    val connectionId = "account-$index"
                    component.connections().upsert(ProviderConnection(
                        id = connectionId, source = BookSource.GRIMMORY, name = connectionId,
                        serverUrl = "http://127.0.0.1:${server.port}", username = "fixture", urlScheme = UrlScheme.HTTP,
                    ))
                    Book(id = "7", title = "Shared ID", source = BookSource.GRIMMORY,
                        connectionId = connectionId, mediaType = AppMediaType.AUDIOBOOK,
                        duration = 1000, currentTime = 100, readProgress = 0.1f)
                        .also { component.bookCacheDao().insertIfAbsent(it.toCachedBook()) }
                }
                val result = GrimmoryAudiobookSyncStrategy(component.aggregator(), component.bookCacheDao())
                    .sync(force = true, launchOptimized = false)
                assertEquals(2, result.pulled)
                books.zip(listOf(800L, 400L)).forEach { (book, expected) ->
                    assertEquals(expected, component.bookCacheDao().getByIdAndConnection(book.id, book.connectionId)!!.currentTime)
                    assertEquals("Narrator $expected", component.aggregator().fetchAudiobookNarrator(book).getOrThrow())
                }
                for (index in listOf(0, 1, 0, 1)) {
                    val recent = withContext(ConnectionScope.asContextElement("account-$index")) {
                        component.grimmoryRepository().getRecentlyAdded().getOrThrow()
                    }
                    assertEquals("Server ${if (index == 0) 80 else 40}", recent.single().title)
                }
            } finally {
                servers.forEach { it.close() }
            }
        }
    }

    @Test
    fun pendingCountTracksThePersistentRetryQueue() = runBlocking {
        withProfile { component ->
            val queue = component.database().pendingProgressPushDao()
            assertEquals(0, queue.observeCount().first())
            val item = PendingProgressPush(
                bookId = "7", connectionKey = "first", mediaType = AppMediaType.EBOOK.name,
                percentage = 0.3f, isFinished = false, createdAt = 1,
            )
            queue.upsert(item)
            queue.upsert(item.copy(connectionKey = "second"))
            assertEquals(2, withTimeout(5000) { queue.observeCount().first { it == 2 } })
            queue.delete(item.bookId, item.source, item.connectionKey)
            assertEquals(1, withTimeout(5000) { queue.observeCount().first { it == 1 } })
        }
    }

    @Test
    fun concurrentKOReaderLinkUpdatesDoNotLoseEntries() = runBlocking {
        withProfile { component ->
            val hub = component.koReaderHubService()
            coroutineScope {
                val start = CompletableDeferred<Unit>()
                repeat(32) { index ->
                    launch(Dispatchers.Default) {
                        start.await()
                        val book = Book(id = "link-$index", title = "Link $index", source = BookSource.LOCAL)
                        hub.link(book, "a".repeat(32), isAutomatic = false)
                        hub.linkFilename(book, "$index.epub")
                    }
                }
                start.complete(Unit)
            }
            assertEquals(32, hub.links.size)
            assertEquals(32, hub.links.count { !it.filename.isNullOrBlank() })
        }
    }

    private suspend fun withProfile(block: suspend (com.enve.app.profiles.ProfileRuntimeComponent) -> Unit) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val id = UUID.randomUUID().toString()
        val runtimes = ProfileRuntimeRegistry(context)
        val component = runtimes.open(id)
        val locations = component.storageLocations()
        try {
            block(component)
        } finally {
            component.vault().clearAll()
            runtimes.close(id)
            locations.filesDirectory.deleteRecursively()
            locations.cacheDirectory.deleteRecursively()
            locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }

    private class ProgressServer(private val percent: Int) : AutoCloseable {
        private val socket = ServerSocket(0)
        val port: Int get() = socket.localPort
        private val worker = thread(isDaemon = true, name = "progress-fixture") {
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                client.use {
                    val input = it.getInputStream().bufferedReader()
                    val request = input.readLine() ?: return@use
                    while (!input.readLine().isNullOrEmpty()) { }
                    val path = request.substringAfter(' ').substringBefore(' ').substringBefore('?')
                    val body = when {
                        path.endsWith("/recently-added") -> """[{"id":"recent","title":"Server $percent","primaryFileType":"EPUB"}]"""
                        path.endsWith("/7/progress") -> """{"readStatus":"READING","audiobookProgress":{"positionMs":${percent * 10000},"trackIndex":0,"percentage":$percent,"updatedAt":"2099-01-01T00:00:00Z"}}"""
                        path.endsWith("/7/info") -> """{"bookId":"7","narrator":"Narrator ${percent * 10}","durationMs":1000000}"""
                        path.endsWith("/7") -> """{"id":"7","title":"Shared ID","primaryFileType":"AUDIOBOOK"}"""
                        else -> "[]"
                    }.toByteArray()
                    val status = if (path.endsWith("/7/progress") || path.endsWith("/7/info") || path.endsWith("/7") || path.endsWith("/recently-added")) "200 OK" else "404 Not Found"
                    val output = it.getOutputStream()
                    output.write("HTTP/1.1 $status\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
                    output.write(body)
                    output.flush()
                }
            }
        }
        override fun close() {
            socket.close()
            worker.join(1000)
        }
    }
}
