package com.enve.app.data.remote

import org.junit.Assert.assertEquals
import org.junit.Test
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.PUT

class GrimmoryApiContractTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun librariesUseStandardEndpointAndDecodeTheServerShape() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val api = Retrofit.Builder()
                .baseUrl(server.url("/"))
                .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
                .build()
                .create(GrimmoryApi::class.java)
            val body = """[{"id":7,"name":"Books","allowedFormats":["EPUB","AUDIOBOOK"],"paths":[{"id":1,"path":"/library"}]}]"""
            repeat(2) { server.enqueue(MockResponse().setBody(body)) }
            val catalog = api.getCatalogLibraries().execute().body()!!.single()
            val browse = api.getLibraries().body()!!.single()
            assertEquals("7", catalog.id)
            assertEquals("Books", catalog.name)
            assertEquals(listOf("EPUB", "AUDIOBOOK"), catalog.allowedFormats)
            assertEquals(catalog, browse)
            repeat(2) { assertEquals("/api/v1/libraries", server.takeRequest().path) }
        }
    }

    @Test
    fun progressUsesOnlyTheCurrentAppEndpoints() {
        assertEquals(
            "api/v1/app/books/{bookId}/progress",
            route("getAppBookProgress", GET::class.java)?.value,
        )
        assertEquals(
            "api/v1/app/books/{bookId}/progress",
            route("putAppBookProgress", PUT::class.java)?.value,
        )
    }

    @Test
    fun readerArtifactsUseDocumentedCrudEndpoints() {
        assertEquals(
            "api/v1/annotations/book/{bookId}",
            route("getAnnotationsForBook", GET::class.java)?.value,
        )
        assertEquals(
            "api/v1/annotations",
            route("createAnnotation", POST::class.java)?.value,
        )
        assertEquals(
            "api/v1/annotations/{annotationId}",
            route("updateAnnotation", PUT::class.java)?.value,
        )
        assertEquals(
            "api/v1/annotations/{serverId}",
            route("deleteAnnotation", DELETE::class.java)?.value,
        )
        assertEquals(
            "api/v2/book-notes/book/{bookId}",
            route("getBookNotesForBook", GET::class.java)?.value,
        )
        assertEquals(
            "api/v2/book-notes",
            route("createBookNote", POST::class.java)?.value,
        )
        assertEquals(
            "api/v1/bookmarks/book/{bookId}",
            route("getBookmarksForBook", GET::class.java)?.value,
        )
        assertEquals(
            "api/v1/bookmarks",
            route("createBookmark", POST::class.java)?.value,
        )
    }

    private fun <T : Annotation> route(
        methodName: String,
        annotation: Class<T>,
    ): T? = GrimmoryApi::class.java.declaredMethods
        .first { it.name == methodName }
        .getAnnotation(annotation)
}
