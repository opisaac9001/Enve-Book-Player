package com.enve.app.data.local

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.BearerAuthHeaderStrategy
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.remote.TokenRefreshContext
import com.enve.core.data.remote.auth.AuthInterceptor
import com.enve.core.data.remote.auth.TokenRefreshCoordinator
import com.enve.silo.api.SiloApi
import com.enve.silo.auth.SiloPasswordLogin
import com.enve.silo.auth.SiloTokenRefreshStrategy
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.inject.Provider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

@RunWith(AndroidJUnit4::class)
class SiloV2AuthenticationTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Test
    fun passwordLoginRefreshFallbackAndProfileHeadersUseV2() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val profile = "silo-auth-test-${UUID.randomUUID()}"
        val root = File(context.cacheDir, profile).also { it.mkdirs() }
        val job = SupervisorJob()
        val scope = CoroutineScope(job + Dispatchers.IO)
        val data = PreferenceDataStoreFactory.create(scope = scope) { File(root, "test.preferences_pb") }
        val vault = CredentialVault.forProfile(context, profile)
        val prefs = PreferencesManager(data, vault, scope)
        val registry = ConnectionRegistry(data)
        val server = MockWebServer()
        server.start()
        val base = server.url("/silo/").toString().trimEnd('/')
        val connection = ProviderConnection("fixture", BookSource.SILO, "Fixture", base, "tester")
        val client = OkHttpClient()
        val api = Retrofit.Builder().baseUrl("$base/")
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .client(client).build().create(SiloApi::class.java)
        fun response(body: String) = MockResponse().setHeader("Content-Type", "application/json").setBody(body)
        fun loginBody(token: String) = """{"access_token":"$token","refresh_token":"refresh-fixture","user":{"id":"account-opaque","username":"tester"}}"""
        try {
            server.enqueue(response(loginBody("login-fixture")))
            assertTrue(SiloPasswordLogin(api, prefs, vault).login(base, "tester", "password-fixture").isSuccess)
            assertEquals("/silo/api/v2/auth/login", server.takeRequest(5, TimeUnit.SECONDS)?.path)
            assertEquals("login-fixture", prefs.getAccessTokenSync())

            val refresh = SiloTokenRefreshStrategy(prefs, vault, Provider { client })
            val auth = TokenRefreshContext(BookSource.SILO, base, connection.id, connection, "refresh-fixture", "tester", "password-fixture")
            server.enqueue(response("""{"access_token":"renewed-fixture","refresh_token":"rotated-fixture"}"""))
            assertEquals("renewed-fixture", refresh.refresh(auth))
            assertEquals("/silo/api/v2/auth/refresh", server.takeRequest(5, TimeUnit.SECONDS)?.path)
            assertEquals("rotated-fixture", vault.get(CredentialVault.refreshTokenKey(connection.id)))

            server.enqueue(MockResponse().setResponseCode(401))
            server.enqueue(response(loginBody("fallback-fixture")))
            assertEquals("fallback-fixture", refresh.refresh(auth))
            assertEquals("/silo/api/v2/auth/refresh", server.takeRequest(5, TimeUnit.SECONDS)?.path)
            assertEquals("/silo/api/v2/auth/login", server.takeRequest(5, TimeUnit.SECONDS)?.path)

            registry.upsert(connection)
            vault.put("silo_profile_id_${connection.id}", "profile-fixture")
            val interceptor = AuthInterceptor(prefs, registry, vault, emptyMap(), BearerAuthHeaderStrategy(), emptyMap(), TokenRefreshCoordinator())
            val signedClient = client.newBuilder().addInterceptor(interceptor).build()
            server.enqueue(response("{}"))
            withContext(ConnectionScope.asContextElement(connection.id) + Dispatchers.IO) {
                signedClient.newCall(Request.Builder().url("$base/api/v2/catalog").build()).execute().use { assertTrue(it.isSuccessful) }
            }
            val request = checkNotNull(server.takeRequest(5, TimeUnit.SECONDS))
            assertEquals("Bearer fallback-fixture", request.getHeader("Authorization"))
            assertEquals("profile-fixture", request.getHeader("X-Profile-Id"))
        } finally {
            server.shutdown()
            job.cancelAndJoin()
            vault.clearAll()
            root.deleteRecursively()
        }
    }
}
