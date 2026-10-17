package com.enve.app.viewmodel

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.playback.AndroidAutoDebugEntryPoint
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.UrlScheme
import dagger.hilt.android.EntryPointAccessors
import java.net.ServerSocket
import java.util.UUID
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GrimmoryComicDirectionTest {
    @Test
    fun providerReadsBothDirectionsAndLeavesMissingMetadataUnknown() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val profiles = EntryPointAccessors.fromApplication(context, AndroidAutoDebugEntryPoint::class.java).profileCoordinator()
        profiles.initialize()
        val component = checkNotNull(profiles.activeRuntime.value).component
        val connectionId = "grimmory-direction-${UUID.randomUUID()}"
        val socket = ServerSocket(0)
        val worker = thread(isDaemon = true, name = "grimmory-direction-fixture") {
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                client.use {
                    val input = it.getInputStream().bufferedReader()
                    val request = input.readLine() ?: return@use
                    while (!input.readLine().isNullOrEmpty()) { }
                    val direction = when {
                        request.contains("/books/rtl ") -> "\"rtl\""
                        request.contains("/books/ltr ") -> "\"ltr\""
                        else -> "null"
                    }
                    val body = """{"metadata":{"authors":[{"name":"Author"}],"comicMetadata":{"readingDirection":$direction}}}""".toByteArray()
                    it.getOutputStream().apply {
                        write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        write(body)
                        flush()
                    }
                }
            }
        }
        try {
            component.connections().upsert(ProviderConnection(
                id = connectionId, source = BookSource.GRIMMORY, name = "Comic metadata test",
                serverUrl = "http://127.0.0.1:${socket.localPort}", username = "", urlScheme = UrlScheme.HTTP,
            ))
            for ((id, expected) in listOf("rtl" to "RIGHT_TO_LEFT", "ltr" to "LEFT_TO_RIGHT", "missing" to null)) {
                val book = Book(id = id, title = "Direction fixture", source = BookSource.GRIMMORY, connectionId = connectionId)
                assertEquals(expected, component.aggregator().getComicReadingDirection(book).getOrThrow())
            }
        } finally {
            component.connections().remove(connectionId)
            socket.close()
            worker.join(2_000)
        }
    }
}
