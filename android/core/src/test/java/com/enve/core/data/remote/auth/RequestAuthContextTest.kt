package com.enve.core.data.remote.auth

import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.AuthCredentialScope
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.remote.LoginAttempt
import com.enve.core.data.remote.LoginAttemptScope
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

class RequestAuthContextTest {
    @Test fun originCredentialsAllowSiblingPathsButRejectOtherOrigins() {
        val base = "https://server.example/opds"
        val scope = AuthCredentialScope.ORIGIN
        assertTrue("https://server.example/get/epub/12/library".toHttpUrl().belongsTo(base, scope))
        assertTrue("https://server.example:443/api/v1/media/12/file".toHttpUrl().belongsTo(base, scope))
        for (url in listOf("http://server.example/get/epub/12", "https://server.example:8443/get/epub/12",
            "https://other.example/get/epub/12")) {
            assertFalse(url.toHttpUrl().belongsTo(base, scope))
        }
    }

    @Test fun originScopedRedirectRetainsCredentialsForAcquisitionOutsideCatalogPath() {
        verifyRedirect(AuthCredentialScope.ORIGIN, foreignOrigin = false, credentialsExpected = true)
    }

    @Test fun originScopedRedirectStripsCredentialsForAnotherPort() {
        verifyRedirect(AuthCredentialScope.ORIGIN, foreignOrigin = true, credentialsExpected = false)
    }

    @Test fun defaultPathScopedRedirectStillStripsCredentialsOutsideServerPath() {
        verifyRedirect(AuthCredentialScope.SERVER_PATH, foreignOrigin = false, credentialsExpected = false)
    }

    @Test fun credentialBoundaryIncludesSchemePortAndServerPath() {
        val base = "https://server.example/books"
        assertTrue("https://server.example/books/api/items".toHttpUrl().belongsTo(base))
        assertTrue("https://server.example/books".toHttpUrl().belongsTo(base))
        for (url in listOf("http://server.example/books", "https://server.example:8443/books",
            "https://other.example/books", "https://server.example/books-elsewhere", "https://server.example/api")) {
            assertFalse(url.toHttpUrl().belongsTo(base))
        }
    }

    @Test fun dispatcherCapturesLoginAttemptAndClearsItBeforeNextWorkItem() {
        val executor = ConnectionScope.propagatingExecutor(Executors.newSingleThreadExecutor())
        val attempts = LinkedBlockingQueue<String>()
        val attempt = LoginAttempt("https://fixture.example", BookSource.GRIMMORY, emptyMap())
        try {
            LoginAttemptScope.withAttempt(attempt) {
                ConnectionScope.withConnectionId("connection") {
                    executor.execute {
                        assertSame(attempt, LoginAttemptScope.get())
                        attempts.add(ConnectionScope.getConnectionId() ?: "missing")
                    }
                }
            }
            executor.execute {
                attempts.add(if (LoginAttemptScope.get() == null && ConnectionScope.getConnectionId() == null) "clear" else "leaked")
            }
            assertEquals("connection", attempts.poll(5, TimeUnit.SECONDS))
            assertEquals("clear", attempts.poll(5, TimeUnit.SECONDS))
        } finally {
            executor.shutdownNow()
        }
    }

    private fun verifyRedirect(scope: AuthCredentialScope, foreignOrigin: Boolean, credentialsExpected: Boolean) {
        MockWebServer().use { catalog ->
            MockWebServer().use { other ->
                catalog.start()
                other.start()
                val destination = if (foreignOrigin) other else catalog
                catalog.enqueue(MockResponse().setResponseCode(302)
                    .addHeader("Location", destination.url("/get/epub/12/library")))
                destination.enqueue(MockResponse().setBody("book"))
                val request = Request.Builder()
                    .url(catalog.url("/opds/acquire/12"))
                    .header("Authorization", "Basic fixture")
                    .header("Cookie", "session=fixture")
                    .header("X-Catalog-Key", "fixture")
                    .tag(RequestAuthContext::class.java, RequestAuthContext(
                        "catalog", catalog.url("/opds").toString(),
                        setOf("Authorization", "Cookie", "X-Catalog-Key"), scope,
                    ))
                    .build()
                val client = OkHttpClient.Builder()
                    .addNetworkInterceptor(ConnectionAuthRedirectInterceptor())
                    .build()
                try {
                    client.newCall(request).execute().use { assertEquals(200, it.code) }
                    assertEquals("Basic fixture", catalog.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("Authorization"))
                    val acquired = destination.takeRequest(5, TimeUnit.SECONDS)!!
                    assertEquals(if (credentialsExpected) "Basic fixture" else null, acquired.getHeader("Authorization"))
                    assertEquals(if (credentialsExpected) "session=fixture" else null, acquired.getHeader("Cookie"))
                    assertEquals(if (credentialsExpected) "fixture" else null, acquired.getHeader("X-Catalog-Key"))
                } finally {
                    client.connectionPool.evictAll()
                    client.dispatcher.executorService.shutdownNow()
                }
            }
        }
    }
}
