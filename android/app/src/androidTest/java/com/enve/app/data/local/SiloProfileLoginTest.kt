package com.enve.app.data.local

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.ConnectionScope
import com.enve.silo.SiloRepository
import com.enve.silo.SiloPlaybackInstallations
import com.enve.silo.SiloCatalogCursors
import com.enve.silo.api.SiloApi
import com.enve.silo.auth.SiloProfileChoice
import com.enve.silo.auth.SiloProfileLogin
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.Json
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import java.io.File
import java.util.UUID
import javax.inject.Provider

@RunWith(AndroidJUnit4::class)
class SiloProfileLoginTest {
    private val json = Json { ignoreUnknownKeys = true }
    @Test fun selectedProfileProofIsIsolatedAndReauthenticationKeepsTheProfile() = runBlocking {
        fixture { vault, registry, client ->
            val flow = SiloProfileLogin(Provider { client }, vault, registry)
            val first = async { flow.prepare("http://silo.invalid", emptyMap(), null) }
            assertEquals(2, flow.state.first { it.isNotEmpty() }.size)
            flow.choose(SiloProfileChoice("locked", "1234"))
            val id = first.await()
            assertEquals("locked", vault.get("silo_profile_id_$id"))
            assertEquals("proof", vault.get("silo_profile_token_$id"))
            registry.upsert(ProviderConnection(id, BookSource.SILO, "Fixture", "http://silo.invalid", "reader"))
            val again = async { flow.prepare("http://silo.invalid", emptyMap(), id) }
            assertEquals(listOf("locked"), flow.state.first { it.isNotEmpty() }.map { it.id })
            flow.choose(SiloProfileChoice("locked", "1234"))
            assertEquals(id, again.await())
            assertEquals("original-proof", vault.get("silo_profile_token_other"))
        }
    }

    @Test fun invalidPINAndWrongAccountCannotReplaceStoredBinding() = runBlocking {
        fixture { vault, registry, client ->
            val flow = SiloProfileLogin(Provider { client }, vault, registry)
            val rejected = async { runCatching { flow.prepare("http://silo.invalid", emptyMap(), null) } }
            flow.state.first { it.isNotEmpty() }
            flow.choose(SiloProfileChoice("locked", "0000"))
            assertTrue(rejected.await().isFailure)
            assertNull(vault.get("silo_profile_id_silo|http://silo.invalid|reader|locked"))
            registry.upsert(ProviderConnection("other", BookSource.SILO, "Other", "http://silo.invalid", "owner"))
            assertTrue(runCatching { flow.prepare("http://silo.invalid", emptyMap(), "other") }.isFailure)
            assertEquals("original-proof", vault.get("silo_profile_token_other"))
        }
    }

    @Test fun missingScopedConnectionNeverUsesAnotherServer() = runBlocking {
        fixture { vault, registry, client ->
            registry.upsert(ProviderConnection("other", BookSource.SILO, "Other", "http://silo.invalid", "owner"))
            val api = Retrofit.Builder().baseUrl("http://silo.invalid/").client(client)
                .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
                .build().create(SiloApi::class.java)
            val repository = SiloRepository(api, vault, registry, SiloPlaybackInstallations(api), SiloCatalogCursors())
            withContext(ConnectionScope.asContextElement("removed")) {
                assertTrue(repository.getLibraries().isFailure)
            }
            assertNull(vault.get("silo_profile_id_other"))
        }
    }

    private suspend fun fixture(block: suspend CoroutineScope.(CredentialVault, ConnectionRegistry, OkHttpClient) -> Unit) = coroutineScope {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val identity = "silo-profile-${UUID.randomUUID()}"
        val root = File(context.cacheDir, identity).also { it.mkdirs() }
        val job = SupervisorJob()
        val vault = CredentialVault.forProfile(context, identity)
        val registry = ConnectionRegistry(PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) { File(root, "connections.preferences_pb") })
        vault.put(CredentialVault.KEY_ACCESS_TOKEN, "access")
        vault.put("silo_profile_token_other", "original-proof")
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            assertNull(request.header("X-Profile-Id"))
            assertNull(request.header("X-Profile-Token"))
            val body = if (request.url.encodedPath == "/api/v2/account/me") {
                """{"id":"u-1","username":"reader"}"""
            } else if (request.url.encodedPath == "/api/v2/profiles") {
                """{"items":[{"id":"primary","name":"Primary","is_primary":true,"has_pin":false},{"id":"locked","name":"Locked","is_primary":false,"has_pin":true}]}"""
            } else {
                val buffer = okio.Buffer().also { request.body!!.writeTo(it) }
                if (buffer.readUtf8().contains("1234")) """{"valid":true,"profile_token":"proof"}""" else """{"valid":false}"""
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(body.toResponseBody("application/json".toMediaType())).build()
        }.build()
        try { withTimeout(15_000) { block(vault, registry, client) } }
        finally { job.cancelAndJoin(); vault.clearAll(); root.deleteRecursively() }
    }
}
