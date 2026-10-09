package com.enve.app.viewmodel

import android.content.Context
import android.graphics.Bitmap
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.playback.AndroidAutoDebugEntryPoint
import com.enve.app.ui.screens.ReaderFormat
import com.enve.core.data.local.ComicReadingDirectionOverrideStore
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.UrlScheme
import dagger.hilt.android.EntryPointAccessors
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.ServerSocket
import java.util.UUID
import kotlin.concurrent.thread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KomgaComicDirectionTest {
    @Test
    fun serverLTRWinsOverSavedRTLWhenOpeningAComic() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val profiles = EntryPointAccessors.fromApplication(context, AndroidAutoDebugEntryPoint::class.java)
            .profileCoordinator()
        profiles.initialize()
        val component = checkNotNull(profiles.activeRuntime.value).component
        val connectionId = "comic-direction-${UUID.randomUUID()}"
        val directory = File(context.cacheDir, connectionId).apply { mkdirs() }
        val job = SupervisorJob()
        val dataStore = PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) {
            File(directory, "direction.preferences_pb")
        }
        val overrides = ComicReadingDirectionOverrideStore(dataStore)
        val viewModels = ViewModelStore()
        val server = FixtureServer()
        try {
            overrides.save("another-issue", "RIGHT_TO_LEFT")
            component.connections().upsert(ProviderConnection(
                id = connectionId, source = BookSource.KOMGA, name = "Direction test",
                serverUrl = "http://127.0.0.1:${server.port}", username = "", urlScheme = UrlScheme.HTTP,
            ))
            val reader = withContext(Dispatchers.Main) {
                ComicReaderViewModel(
                    context, component.preferences(), component.grimmoryRepository(), component.aggregator(),
                    component.annotationRepository(), component.komgaRepository(), component.comicDownloads(),
                    component.bookCacheDao(), component.serverPageStreamingService(), overrides,
                    component.storageLocations(), component.database(),
                ).also {
                    viewModels.put("reader", it)
                    it.initialize(ComicReaderArgs(
                        bookId = "issue", bookSource = BookSource.KOMGA, connectionId = connectionId,
                        title = "LTR manga fixture", author = "Enve", format = ReaderFormat.CBZ, locator = null,
                    ))
                }
            }
            val loaded = withTimeout(20_000) { reader.state.first { !it.isLoading } }
            assertNull(loaded.error)
            assertEquals(3, loaded.pages.size)
            assertEquals(ComicReadingDirection.LEFT_TO_RIGHT, loaded.settings.readingDirection)
        } finally {
            withContext(Dispatchers.Main) { viewModels.clear() }
            component.connections().remove(connectionId)
            job.cancelAndJoin()
            server.close()
            directory.deleteRecursively()
        }
    }

    private class FixtureServer : AutoCloseable {
        private val socket = ServerSocket(0)
        val port: Int get() = socket.localPort
        private val page = ByteArrayOutputStream().also { output ->
            Bitmap.createBitmap(200, 300, Bitmap.Config.ARGB_8888).also {
                it.eraseColor(android.graphics.Color.WHITE)
                it.compress(Bitmap.CompressFormat.PNG, 100, output)
                it.recycle()
            }
        }.toByteArray()
        private val worker = thread(isDaemon = true, name = "komga-direction-fixture") {
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                client.use {
                    val input = it.getInputStream().bufferedReader()
                    val request = input.readLine() ?: return@use
                    while (!input.readLine().isNullOrEmpty()) { }
                    val method = request.substringBefore(' ')
                    val path = request.substringAfter(' ').substringBefore(' ').substringBefore('?')
                    val body = when {
                        method != "GET" -> byteArrayOf()
                        path.endsWith("/pages") -> """[{"number":1,"fileName":"1.png","mediaType":"image/png"},{"number":2,"fileName":"2.png","mediaType":"image/png"},{"number":3,"fileName":"3.png","mediaType":"image/png"}]""".toByteArray()
                        path.contains("/pages/") -> page
                        path.endsWith("/series/ltr") -> """{"id":"ltr","libraryId":"manga","name":"Manga","metadata":{"readingDirection":"LEFT_TO_RIGHT"}}""".toByteArray()
                        path.endsWith("/books/issue") -> """{"id":"issue","seriesId":"ltr","seriesTitle":"Manga","libraryId":"manga","name":"issue.cbz","media":{"status":"READY","mediaType":"application/zip","pagesCount":3}}""".toByteArray()
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
