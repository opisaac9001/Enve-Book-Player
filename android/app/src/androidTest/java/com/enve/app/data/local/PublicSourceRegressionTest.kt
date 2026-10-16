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
    fun audiobookshelfCollectionsLoadFromLiveServer() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val fixtureFile = java.io.File(context.filesDir, "abs-collections-live.json")
        org.junit.Assume.assumeTrue("Live server fixture is not configured", fixtureFile.exists())
        val fixture = org.json.JSONObject(fixtureFile.readText())
        withProfile { component ->
            val url = fixture.getString("serverUrl")
            val username = fixture.getString("username")
            val connectionId = "audiobookshelf|$url|$username"
            component.connections().upsert(ProviderConnection(
                id = connectionId, source = BookSource.AUDIOBOOKSHELF, name = "Live collections test",
                serverUrl = url, username = username, urlScheme = UrlScheme.HTTP,
            ))
            component.vault().put(com.enve.core.auth.CredentialVault.accessTokenKey(connectionId), fixture.getString("token"))
            withContext(ConnectionScope.asContextElement(connectionId)) {
                val libraries = fixture.getJSONArray("libraries")
                for (index in 0 until libraries.length()) {
                    val library = libraries.getJSONObject(index)
                    val rawId = library.getString("libraryId")
                    val collections = component.audiobookshelfRepository()
                        .getCollections("$connectionId::$rawId").getOrThrow()
                    val expected = library.getJSONArray("collectionIds")
                    assertEquals((0 until expected.length()).map { expected.getString(it) }.toSet(),
                        collections.map { it.id }.toSet())
                }
            }
        }
    }

    @Test
    fun audiobookshelfCollectionsUseRemoteLibraryIds() = runBlocking {
        withProfile { component ->
            CollectionServer().use { server ->
                val libraryId = "71b172fc-7dc2-4d3f-9580-af6ea375fd64"
                val url = "http://127.0.0.1:${server.port}"
                val connectionId = "audiobookshelf|$url|fixture"
                component.connections().upsert(ProviderConnection(
                    id = connectionId, source = BookSource.AUDIOBOOKSHELF, name = "Collections fixture",
                    serverUrl = url, username = "fixture", urlScheme = UrlScheme.HTTP,
                ))
                component.vault().put(com.enve.core.auth.CredentialVault.accessTokenKey(connectionId), "fixture-token")
                withContext(ConnectionScope.asContextElement(connectionId)) {
                    val repository = component.audiobookshelfRepository()
                    repository.getCollections("$connectionId::$libraryId").getOrThrow()
                    repository.setCollectionBook(Book(
                        id = "fixture-item", title = "Collections fixture", source = BookSource.AUDIOBOOKSHELF,
                        connectionId = connectionId, libraryId = "$connectionId::$libraryId",
                    ), "Enve Favorites", saved = true).getOrThrow()
                }
                assertEquals(listOf(
                    "GET /api/libraries/$libraryId/collections?limit=500",
                    "GET /api/libraries/$libraryId/collections?limit=500",
                    "POST /api/collections",
                ), server.requests.toList())
                val body = org.json.JSONObject(server.createdCollection)
                assertEquals(libraryId, body.getString("libraryId"))
                assertEquals("fixture-item", body.getJSONArray("books").getString(0))
            }
        }
    }

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

    private class CollectionServer : AutoCloseable {
        private val socket = ServerSocket(0)
        val port: Int get() = socket.localPort
        val requests = java.util.concurrent.CopyOnWriteArrayList<String>()
        @Volatile var createdCollection = ""
        private val worker = thread(isDaemon = true, name = "collections-fixture") {
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                client.use {
                    val input = it.getInputStream().bufferedReader()
                    val request = input.readLine() ?: return@use
                    var length = 0
                    while (true) {
                        val header = input.readLine() ?: break
                        if (header.isEmpty()) break
                        if (header.startsWith("Content-Length:", ignoreCase = true)) {
                            length = header.substringAfter(':').trim().toInt()
                        }
                    }
                    requests += request.substringBeforeLast(' ')
                    if (length > 0) {
                        val payload = CharArray(length)
                        var offset = 0
                        while (offset < length) {
                            val count = input.read(payload, offset, length - offset)
                            if (count < 0) break
                            offset += count
                        }
                        createdCollection = String(payload, 0, offset)
                    }
                    val body = if (request.startsWith("POST ")) {
                        """{"id":"fixture-collection","name":"Enve Favorites","books":[{"id":"fixture-item"}]}"""
                    } else { """{"results":[]}""" }
                    val bytes = body.toByteArray()
                    val output = it.getOutputStream()
                    output.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                    output.write(bytes)
                    output.flush()
                }
            }
        }
        override fun close() {
            socket.close()
            worker.join(1000)
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
