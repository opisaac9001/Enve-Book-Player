package com.enve.app.data.repository

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.remote.GrimmoryApi
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
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

@RunWith(AndroidJUnit4::class)
class TorBoxCatalogTest {
    @Test
    fun selectedRootsLoadConcurrentlyWithoutScanningOtherFolders() = runBlocking {
        val scope = CoroutineScope(Dispatchers.IO)
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
            val catalog = TorBoxCatalog(TorBoxTransport(api, client), TorBoxCatalogStore(scope))
            val account = TorBoxAccount("test", "https://api.torbox.app/v1/api", "fixture", listOf("Books/Selected"))
            suspend fun load() = catalog.audioFiles(account, account.rootPaths, awaitFolders = true)
            val files = load()
            assertEquals(listOf("/", "/Books/", "/Books/Selected/"), folders)
            assertEquals(setOf("Books/Selected/Book.m4b", "Books/Selected/Available.m4b"), files.map { it.path }.toSet())
            val available = files.single { it.name == "Available.m4b" }
            assertTrue(available.link.contains("/requestdl"))
            assertTrue(available.coverUrl != null)
            val initialCalls = apiCalls.get()
            assertEquals(files, load())
            assertEquals(initialCalls, apiCalls.get())
            assertEquals(3, folders.size)
            freshExpected.set(true)
            catalog.invalidate()
            assertEquals(files, load())
            assertEquals(initialCalls * 2, apiCalls.get())
            assertEquals(6, folders.size)
        } finally {
            scope.cancel()
        }
    }
}
