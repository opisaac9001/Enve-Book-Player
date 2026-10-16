package com.enve.app.data.local

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.app.profiles.ProfileRuntimeRegistry
import com.enve.core.data.model.BookSource
import com.enve.core.auth.CredentialVault
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import java.util.Collections
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn

@RunWith(AndroidJUnit4::class)
class TorBoxLibraryLoadingTest {
    @Test
    fun selectedRootsLoadConcurrentlyWithoutScanningOtherFolders() = runBlocking {
        val runtimes = ProfileRuntimeRegistry(ApplicationProvider.getApplicationContext<Context>())
        val id = UUID.randomUUID().toString()
        val component = runtimes.open(id)
        val locations = component.storageLocations()
        try {
            val started = CountDownLatch(4)
            val freshExpected = AtomicBoolean(false)
            val apiCalls = AtomicInteger()
            val folders = Collections.synchronizedList(mutableListOf<String>())
            val client = OkHttpClient.Builder().addInterceptor { chain ->
                val request = chain.request()
                val path = request.url.encodedPath
                if ((request.method == "GET" && request.url.queryParameter("offset") == "0") || path == "/") {
                    started.countDown()
                    assertTrue("All sources must start before any finishes", started.await(5, TimeUnit.SECONDS))
                }
                val body = if (request.method == "GET") {
                    apiCalls.incrementAndGet()
                    if (freshExpected.get()) assertEquals("true", request.url.queryParameter("bypass_cache"))
                    else assertNull(request.url.queryParameter("bypass_cache"))
                    if (path.contains("/torrents/") && request.url.queryParameter("offset") == "0") {
                        """{"success":true,"data":[{"id":1,"name":"Books/Selected","download_present":false,"download_finished":true,"files":[{"id":1,"name":"Books/Selected/Expired.m4b","short_name":"Expired.m4b"}]},{"id":2,"name":"Books/Selected","download_present":true,"download_finished":false,"files":[{"id":2,"name":"Books/Selected/Available.m4b","short_name":"Available.m4b"}]}]}"""
                    } else """{"success":true,"data":[]}"""
                } else {
                    folders.add(path)
                    val entries = when (path) {
                        "/" -> listOf("Books/", "Unrelated/")
                        "/Books/" -> listOf("Books/Selected/", "Books/Sibling/")
                        "/Books/Selected/" -> listOf("Books/Selected/Book.m4b", "Books/Selected/Available.m4b", "Books/Selected/cover.jpg")
                        else -> error("Unexpected folder $path")
                    }
                    entries.joinToString("", "<multistatus>", "</multistatus>") { "<response><href>/$it</href></response>" }
                }
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                    .body(body.toResponseBody("application/json".toMediaType())).build()
            }.build()
            val api = Retrofit.Builder().baseUrl("https://api.torbox.app/").client(client)
                .addConverterFactory(Json.asConverterFactory("application/json".toMediaType()))
                .build().create(GrimmoryApi::class.java)
            val repository = component.grimmoryRepository()
            GrimmoryRepository::class.java.getDeclaredField("api").apply { isAccessible = true }.set(repository, api)
            GrimmoryRepository::class.java.getDeclaredField("torBoxWebDavClient\$delegate")
                .apply { isAccessible = true }.set(repository, lazyOf(client))
            val contextType = GrimmoryRepository::class.java.declaredClasses.single { it.simpleName == "ScopedContext" }
            val context = contextType.declaredConstructors.single { it.parameterCount == 6 }
                .apply { isAccessible = true }
                .newInstance(BookSource.TORBOX, "https://api.torbox.app/v1/api", "fixture", id, "fixture", emptyList<String>())
            val method = GrimmoryRepository::class.java.declaredMethods.single { it.name == "fetchTorBoxAudioFiles" }
                .apply { isAccessible = true }
            suspend fun load() = suspendCoroutineUninterceptedOrReturn<List<*>> { continuation ->
                method.invoke(repository, context, listOf("Books/Selected"), true, continuation)
            }
            val files = load()
            assertEquals(listOf("/", "/Books/", "/Books/Selected/"), folders)
            val paths = files.map { file ->
                file!!.javaClass.getDeclaredField("path").apply { isAccessible = true }.get(file)
            }.toSet()
            assertEquals(setOf("Books/Selected/Book.m4b", "Books/Selected/Available.m4b"), paths)
            val available = files.first { file ->
                file!!.javaClass.getDeclaredField("path").apply { isAccessible = true }.get(file) == "Books/Selected/Available.m4b"
            }!!
            val link = available.javaClass.getDeclaredField("link").apply { isAccessible = true }.get(available) as String
            assertTrue(link.contains("/requestdl"))
            assertTrue(available.javaClass.getDeclaredField("coverUrl").apply { isAccessible = true }.get(available) != null)
            val initialCalls = apiCalls.get()
            assertEquals(files, load())
            assertEquals(initialCalls, apiCalls.get())
            assertEquals(3, folders.size)
            freshExpected.set(true)
            repository.invalidateListCaches()
            assertEquals(files, load())
            assertEquals(initialCalls * 2, apiCalls.get())
            assertEquals(6, folders.size)
        } finally {
            runtimes.close(id)
            locations.filesDirectory.deleteRecursively()
            locations.cacheDirectory.deleteRecursively()
            locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }
    @Test
    fun rejectedTokenDoesNotReplaceSavedCredentials() = runBlocking {
        val runtimes = ProfileRuntimeRegistry(ApplicationProvider.getApplicationContext<Context>())
        val id = UUID.randomUUID().toString()
        val component = runtimes.open(id)
        val locations = component.storageLocations()
        try {
            val originalSource = component.preferences().getActiveBookSourceSync()
            component.vault().put(CredentialVault.KEY_ACCESS_TOKEN, "existing-fixture")
            val repository = component.grimmoryRepository()
            for (status in listOf(401, 403, 200)) {
                val client = OkHttpClient.Builder().addInterceptor { chain ->
                    assertEquals("Bearer rejected-fixture", chain.request().header("Authorization"))
                    Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                        .code(status).message("Fixture")
                        .body("""{"success":false,"error":"BAD_TOKEN","detail":"private-fixture"}"""
                            .toResponseBody("application/json".toMediaType())).build()
                }.build()
                GrimmoryRepository::class.java.getDeclaredField("torBoxWebDavClient\$delegate")
                    .apply { isAccessible = true }.set(repository, lazyOf(client))
                val result = repository.loginWithToken(BookSource.TORBOX, "https://api.torbox.app/v1/api", "", "rejected-fixture")
                assertTrue(result.isFailure)
                assertTrue(!result.exceptionOrNull()!!.message!!.contains("private-fixture"))
                assertEquals("existing-fixture", component.vault().get(CredentialVault.KEY_ACCESS_TOKEN))
                assertTrue(component.connections().getConnectionsSync().isEmpty())
                assertEquals(originalSource, component.preferences().getActiveBookSourceSync())
            }
        } finally {
            runtimes.close(id)
            locations.filesDirectory.deleteRecursively()
            locations.cacheDirectory.deleteRecursively()
            locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }

    @Test
    fun downloadedTorBoxTrackMeasuresDurationWhenApiHasNone() = runBlocking {
        val runtimes = ProfileRuntimeRegistry(ApplicationProvider.getApplicationContext<Context>())
        val id = UUID.randomUUID().toString()
        val component = runtimes.open(id)
        val locations = component.storageLocations()
        try {
            val dataSize = 32_000
            val wav = ByteBuffer.allocate(44 + dataSize).order(ByteOrder.LITTLE_ENDIAN)
                .put("RIFF".toByteArray()).putInt(36 + dataSize).put("WAVEfmt ".toByteArray())
                .putInt(16).putShort(1).putShort(1).putInt(16_000).putInt(32_000)
                .putShort(2).putShort(16).put("data".toByteArray()).putInt(dataSize).array()
            val file = File(locations.cacheDirectory, "duration-fixture.wav").apply {
                check(parentFile!!.isDirectory || parentFile!!.mkdirs())
                writeBytes(wav)
            }
            val method = component.downloads().javaClass.getDeclaredMethod(
                "downloadedTrackDuration", BookSource::class.java, Long::class.javaPrimitiveType, File::class.java,
            ).apply { isAccessible = true }
            assertEquals(1000L, method.invoke(component.downloads(), BookSource.TORBOX, 0L, file))
        } finally {
            runtimes.close(id)
            locations.filesDirectory.deleteRecursively()
            locations.cacheDirectory.deleteRecursively()
            locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }

}
