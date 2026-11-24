package com.enve.app.data.local

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.BearerAuthHeaderStrategy
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.remote.LoginAttempt
import com.enve.core.data.remote.LoginAttemptScope
import com.enve.core.data.remote.TokenRefreshContext
import com.enve.core.data.remote.TokenRefreshStrategy
import com.enve.core.data.remote.auth.AuthInterceptor
import com.enve.core.data.remote.auth.ConnectionAuthRedirectInterceptor
import com.enve.core.data.remote.auth.TokenRefreshAuthenticator
import com.enve.core.data.remote.auth.TokenRefreshCoordinator
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ConnectionCredentialIsolationTest {
    private class Fixture {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val id = "credential-test-${UUID.randomUUID()}"
        val root = File(context.cacheDir, id).also { it.mkdirs() }
        val job = SupervisorJob()
        val scope = CoroutineScope(job + Dispatchers.IO)
        val data = PreferenceDataStoreFactory.create(scope = scope) { File(root, "prefs.preferences_pb") }
        val vault = CredentialVault.forProfile(context, id)
        val prefs = PreferencesManager(data, vault, scope)
        val registry = ConnectionRegistry(data, vault)
        val a = MockWebServer().apply { start() }
        val b = MockWebServer().apply { start() }
        val account = ProviderConnection("a", BookSource.GRIMMORY, "A", a.url("/").toString(), "a")
        val coordinator = TokenRefreshCoordinator()
        val refreshes = mutableListOf<String?>()
        val strategy = object : TokenRefreshStrategy {
            override fun refresh(context: TokenRefreshContext): String {
                refreshes += context.connectionId
                return "renewed-${context.connectionId}"
            }
        }
        val strategies = mapOf(BookSource.GRIMMORY to strategy)
        val requestScope = com.enve.core.data.remote.RequestScopeInterceptor()
        val client = OkHttpClient.Builder()
            .eventListenerFactory(requestScope)
            .addInterceptor(requestScope)
            .addInterceptor(AuthInterceptor(prefs, registry, vault, emptyMap(), BearerAuthHeaderStrategy(), strategies, coordinator))
            .addNetworkInterceptor(ConnectionAuthRedirectInterceptor())
            .authenticator(TokenRefreshAuthenticator(vault, registry, strategies, coordinator))
            .build()

        suspend fun prepare() {
            registry.upsert(account)
            prefs.setActiveConnectionId(account.id)
            vault.put(CredentialVault.accessTokenKey(account.id), "token-a")
            prefs.saveAuth("global-token", null)
        }

        suspend fun close() {
            client.dispatcher.executorService.shutdownNow()
            client.connectionPool.evictAll()
            a.shutdown()
            b.shutdown()
            job.cancelAndJoin()
            vault.clearAll()
            root.deleteRecursively()
        }
    }

    private fun fixture(block: suspend (Fixture) -> Unit) = runBlocking {
        val f = Fixture()
        try { f.prepare(); block(f) } finally { f.close() }
    }

    @Test fun unrelated401DoesNotBorrowActiveCredentials() = fixture { f ->
        f.b.enqueue(MockResponse().setResponseCode(401))
        f.client.newCall(Request.Builder().url(f.b.url("/media")).build()).execute().use { assertEquals(401, it.code) }
        assertNull(f.b.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("Authorization"))
        assertEquals(1, f.b.requestCount)
        assertTrue(f.refreshes.isEmpty())
    }

    @Test fun refreshUsesOriginatingConnectionAfterActiveAccountChanges() = fixture { f ->
        val other = f.account.copy(id = "b", serverUrl = f.b.url("/").toString())
        f.registry.upsert(other)
        f.prefs.setActiveConnectionId(other.id)
        f.vault.put(CredentialVault.accessTokenKey(other.id), "token-b")
        f.a.enqueue(MockResponse().setResponseCode(401))
        f.a.enqueue(MockResponse().setBody("ok"))
        ConnectionScope.withConnectionId(f.account.id) {
            f.client.newCall(Request.Builder().url(f.a.url("/api/items")).build()).execute().use { assertEquals(200, it.code) }
        }
        assertEquals("Bearer token-a", f.a.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("Authorization"))
        assertEquals("Bearer renewed-a", f.a.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("Authorization"))
        assertEquals(listOf("a"), f.refreshes)
    }

    @Test fun scopedRequestCannotFallBackToAnotherSavedConnection() = fixture { f ->
        f.registry.upsert(f.account.copy(id = "b", serverUrl = f.b.url("/").toString()))
        f.vault.put(CredentialVault.accessTokenKey("b"), "token-b")
        f.b.enqueue(MockResponse().setResponseCode(401))
        ConnectionScope.withConnectionId("a") {
            f.client.newCall(Request.Builder().url(f.b.url("/api/items")).build()).execute().close()
        }
        assertNull(f.b.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("Authorization"))
        assertTrue(f.refreshes.isEmpty())
    }

    @Test fun newLoginUsesOnlyItsOwnAccessToken() = fixture { f ->
        val attempt = LoginAttempt(f.b.url("/").toString(), BookSource.GRIMMORY, emptyMap())
        kotlinx.coroutines.withContext(LoginAttemptScope.asContextElement(attempt)) {
            fun requestToken(): String? {
                f.b.enqueue(MockResponse())
                f.client.newCall(Request.Builder().url(f.b.url("/api/me")).build()).execute().close()
                return f.b.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("Authorization")
            }
            assertNull(requestToken())
            f.prefs.saveAuth("new-account", null)
            assertEquals("Bearer new-account", requestToken())
        }
    }

    @Test fun loginHeadersAreBoundToAttemptAndOriginIncludingSameHostAccounts() = fixture { f ->
        val attempt = LoginAttempt(f.account.serverUrl, BookSource.GRIMMORY,
            mapOf("CF-Access-Client-Secret" to "gateway-fixture", "Cookie" to "session=fixture"))
        f.a.enqueue(MockResponse())
        LoginAttemptScope.withAttempt(attempt) {
            f.client.newCall(Request.Builder().url(f.a.url("/auth/login")).build()).execute().close()
        }
        assertEquals("gateway-fixture", f.a.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("CF-Access-Client-Secret"))
        for (server in listOf(f.a, f.b)) {
            server.enqueue(MockResponse())
            f.client.newCall(Request.Builder().url(server.url("/auth/refresh")).build()).execute().close()
            val request = server.takeRequest(5, TimeUnit.SECONDS)!!
            assertNull(request.getHeader("Cookie"))
            assertNull(request.getHeader("CF-Access-Client-Secret"))
        }
        f.b.enqueue(MockResponse())
        LoginAttemptScope.withAttempt(attempt) {
            f.client.newCall(Request.Builder().url(f.b.url("/auth/login")).build()).execute().close()
        }
        assertNull(f.b.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("Cookie"))
    }

    @Test fun pendingLoginConnectionCanVerifyItsTokenWithoutEnablingBackgroundAccess() = fixture { f ->
        val pending = f.account.copy(id = "pending", enabled = false)
        f.registry.upsert(pending)
        f.vault.put(CredentialVault.accessTokenKey(pending.id), "new-token")
        val attempt = LoginAttempt(pending.serverUrl, pending.source, mapOf("X-Gateway" to "fixture"))
        f.a.enqueue(MockResponse())
        LoginAttemptScope.withAttempt(attempt) {
            ConnectionScope.withConnectionId(pending.id) {
                f.client.newCall(Request.Builder().url(f.a.url("/api/me")).build()).execute().close()
            }
        }
        val verification = f.a.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("Bearer new-token", verification.getHeader("Authorization"))
        assertEquals("fixture", verification.getHeader("X-Gateway"))
        f.a.enqueue(MockResponse())
        ConnectionScope.withConnectionId(pending.id) {
            f.client.newCall(Request.Builder().url(f.a.url("/api/me")).build()).execute().close()
        }
        assertNull(f.a.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("Authorization"))
    }

    @Test fun redirectStripsCustomCredentialsAndCannotRefreshForExternalOrigin() = fixture { f ->
        f.registry.upsert(f.account.copy(customHeaders = mapOf("X-Custom-Secret" to "fixture"), serviceClientSecret = "gateway-fixture"))
        f.a.enqueue(MockResponse().setResponseCode(302).setHeader("Location", f.b.url("/media")))
        f.b.enqueue(MockResponse().setResponseCode(401))
        f.client.newCall(Request.Builder().url(f.a.url("/media")).build()).execute().use { assertEquals(401, it.code) }
        assertEquals("fixture", f.a.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("X-Custom-Secret"))
        val external = f.b.takeRequest(5, TimeUnit.SECONDS)!!
        assertNull(external.getHeader("X-Custom-Secret"))
        assertNull(external.getHeader("CF-Access-Client-Secret"))
        assertNull(external.getHeader("Authorization"))
        assertTrue(f.refreshes.isEmpty())
    }

    @Test fun queuedCallsKeepTheirOwnLoginAttemptWhenDispatchedLater() = fixture { f ->
        f.client.dispatcher.maxRequestsPerHost = 1
        val completed = java.util.concurrent.CountDownLatch(2)
        val failures = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()
        val callback = object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
                failures.add(e)
                completed.countDown()
            }
            override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
                response.use { it.body?.string() }
                completed.countDown()
            }
        }
        f.a.enqueue(MockResponse().setBody("first").setBodyDelay(1, TimeUnit.SECONDS))
        f.a.enqueue(MockResponse().setBody("second"))
        for (secret in listOf("first-fixture", "second-fixture")) {
            val attempt = LoginAttempt(f.account.serverUrl, BookSource.GRIMMORY,
                mapOf("CF-Access-Client-Secret" to secret))
            LoginAttemptScope.withAttempt(attempt) {
                f.client.newCall(Request.Builder().url(f.a.url("/auth/login")).build()).enqueue(callback)
            }
        }
        assertTrue(completed.await(10, TimeUnit.SECONDS))
        assertTrue(failures.isEmpty())
        assertEquals("first-fixture", f.a.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("CF-Access-Client-Secret"))
        assertEquals("second-fixture", f.a.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("CF-Access-Client-Secret"))
    }

    @Test fun missingScopedTokenDoesNotUseGlobalToken() = fixture { f ->
        f.vault.remove(CredentialVault.accessTokenKey("a"))
        f.a.enqueue(MockResponse())
        f.client.newCall(Request.Builder().url(f.a.url("/api/items")).build()).execute().close()
        assertNull(f.a.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("Authorization"))
    }

    @Test fun legacyGatewayCredentialsMoveToVaultAndAreRemovedFromPreferences() = fixture { f ->
        val connection = f.account.copy(customHeaders = mapOf("Cookie" to "session=fixture"),
            serviceClientId = "client-fixture", serviceClientSecret = "secret-fixture")
        val key = stringPreferencesKey("enve.connections.json")
        f.data.edit { it[key] = Json.encodeToString(ListSerializer(ProviderConnection.serializer()), listOf(connection)) }
        assertEquals(connection, f.registry.connections.first().single())
        val stored = f.data.data.first()[key]!!
        assertFalse(stored.contains("secret-fixture"))
        assertFalse(stored.contains("session=fixture"))
        val reopened = ConnectionRegistry(f.data, f.vault)
        assertEquals(connection, reopened.getConnectionsSync().single())
        reopened.upsert(connection.copy(customHeaders = emptyMap(), serviceClientId = "", serviceClientSecret = ""))
        assertEquals(emptyMap<String, String>(), reopened.getConnectionsSync().single().customHeaders)
        assertEquals("", reopened.getConnectionsSync().single().serviceClientSecret)
    }

    @Test fun synchronousConnectionLookupDoesNotWaitForAWrite() = fixture { f ->
        val readOnly = object : androidx.datastore.core.DataStore<androidx.datastore.preferences.core.Preferences> {
            override val data = f.data.data

            override suspend fun updateData(
                transform: suspend (androidx.datastore.preferences.core.Preferences) -> androidx.datastore.preferences.core.Preferences,
            ): androidx.datastore.preferences.core.Preferences = error("A synchronous lookup must not enqueue a write")
        }
        assertEquals(f.account, ConnectionRegistry(readOnly, f.vault).getConnectionsSync().single())
    }
}
