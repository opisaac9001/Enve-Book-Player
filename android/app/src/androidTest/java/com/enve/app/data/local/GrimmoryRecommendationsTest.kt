package com.enve.app.data.local

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.GrimmoryRecommendationDto
import com.enve.app.data.servertools.GrimmoryToolsRepository
import com.enve.app.data.servertools.KavitaToolsRepository
import com.enve.app.hearth.ServerToolsFacadeImpl
import com.enve.audiobookshelf.AudiobookshelfPersonalRepository
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.ConnectionScope
import com.enve.silo.*
import com.enve.silo.api.SiloApi
import java.io.File
import java.lang.reflect.Proxy
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import retrofit2.Response

@RunWith(AndroidJUnit4::class)
class GrimmoryRecommendationsTest {
    @Test
    fun formatsResolveOnlyBooksFromTheRequestingConnection() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val name = "recommendations-${UUID.randomUUID()}"
        val root = File(context.cacheDir, name).also { it.mkdirs() }
        val job = SupervisorJob()
        val registry = ConnectionRegistry(PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) {
            File(root, "connections.preferences_pb")
        })
        val vault = CredentialVault.forProfile(context, name)
        val db = Room.inMemoryDatabaseBuilder(context, ReaderDatabase::class.java).build()
        val scopes = mutableListOf<String?>()
        var payload = "[]"
        val api = Proxy.newProxyInstance(GrimmoryApi::class.java.classLoader, arrayOf(GrimmoryApi::class.java)) { _, method, _ ->
            check(method.name == "getBookRecommendations")
            scopes += ConnectionScope.getConnectionId()
            Response.success(Json.decodeFromString<List<GrimmoryRecommendationDto>>(payload))
        } as GrimmoryApi
        val siloApi = unused<SiloApi>()
        val silo = SiloRepository(siloApi, vault, registry, SiloPlaybackInstallations(siloApi), SiloCatalogCursors())
        val facade = ServerToolsFacadeImpl(
            registry, db.bookCacheDao(), unused(), GrimmoryToolsRepository(api), KavitaToolsRepository(api),
            AudiobookshelfPersonalRepository(unused()), SiloPersonalRepository(siloApi, silo),
        )
        try {
            val source = Book("1", "Source", source = BookSource.GRIMMORY, connectionId = "first")
            val first = source.copy(id = "42", title = "First server")
            val second = first.copy(title = "Second server", connectionId = "second")
            val onlySecond = second.copy(id = "43")
            db.bookCacheDao().upsert(listOf(source, first, second, onlySecond).map { it.toCachedBook() })
            for (body in listOf(
                """[{"id":42},{"id":43},{"id":42},{"id":1}]""",
                """[{"book":{"id":42},"similarityScore":0.9},{"book":{"id":43},"similarityScore":0.8}]""",
            )) {
                payload = body
                assertEquals(listOf("First server"), facade.relatedBooks(source, 12).map { it.title })
                assertEquals(listOf("Second server", "Second server"), facade.relatedBooks(source.copy(connectionId = "second"), 12).map { it.title })
            }
            assertEquals(listOf("first", "second", "first", "second"), scopes)
            assertNull(ConnectionScope.getConnectionId())
            assertTrue(facade.relatedBooks(source.copy(connectionId = null), 12).isEmpty())
        } finally {
            db.close()
            job.cancelAndJoin()
            vault.clearAll()
            root.deleteRecursively()
        }
    }

    private inline fun <reified T> unused(): T = Proxy.newProxyInstance(T::class.java.classLoader, arrayOf(T::class.java)) { _, method, _ ->
        error("Unexpected ${method.name}")
    } as T
}
