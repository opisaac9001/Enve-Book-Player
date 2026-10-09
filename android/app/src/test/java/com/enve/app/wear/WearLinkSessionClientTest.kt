package com.enve.app.wear

import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class WearLinkSessionClientTest {
    @Test
    fun audiobookshelfCreatesASeparateRenewableSession() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("""{"user":{"accessToken":"watch-access","refreshToken":"watch-refresh"}}"""))
            server.start()

            val session = WearLinkSessionClient(OkHttpClient()).create(connection(server, BookSource.AUDIOBOOKSHELF), "password")

            assertEquals("watch-access", session.accessToken)
            assertEquals("watch-refresh", session.refreshToken)
            val request = server.takeRequest()
            assertEquals("/login", request.path)
            assertEquals("true", request.getHeader("x-return-tokens"))
            assertEquals("""{"username":"reader","password":"password"}""", request.body.readUtf8())
        }
    }

    @Test
    fun grimmoryCreatesASeparateRenewableSession() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("""{"accessToken":"watch-access","refreshToken":"watch-refresh"}"""))
            server.start()

            val session = WearLinkSessionClient(OkHttpClient()).create(connection(server, BookSource.GRIMMORY), "password")

            assertEquals("watch-access", session.accessToken)
            assertEquals("watch-refresh", session.refreshToken)
            assertEquals("/api/v1/auth/login", server.takeRequest().path)
        }
    }

    @Test
    fun linkRejectsASessionThatCannotRefresh() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("""{"accessToken":"temporary"}"""))
            server.start()

            assertThrows(IllegalStateException::class.java) {
                runBlocking {
                    WearLinkSessionClient(OkHttpClient()).create(connection(server, BookSource.GRIMMORY), "password")
                }
            }
        }
    }

    private fun connection(server: MockWebServer, source: BookSource) = ProviderConnection(
        id = "connection",
        source = source,
        name = "Books",
        serverUrl = server.url("/").toString(),
        username = "reader",
    )
}
