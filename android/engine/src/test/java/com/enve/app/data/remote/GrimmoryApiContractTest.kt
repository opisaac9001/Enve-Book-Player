package com.enve.app.data.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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
    fun malformedBrowsePagesCannotBecomeEmptyCatalogs() {
        val serializer = com.enve.app.data.remote.dto.GrimmoryBrowsePage.serializer(
            com.enve.app.data.remote.dto.LegacyBookloreBookDto.serializer(),
        )
        for (body in listOf(
            "{}",
            """{"content":[],"page":{"number":0,"size":100,"totalElements":2}}""",
            """{"content":[],"page":{"number":0,"size":0,"totalElements":0,"totalPages":0}}""",
            """{"content":[],"page":{"number":0,"size":100,"totalElements":101,"totalPages":1}}""",
        )) {
            assertTrue(runCatching { json.decodeFromString(serializer, body) }.isFailure)
        }
    }

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
    fun progressWritesAndStatusUseCanonicalBookEndpoints() {
        assertEquals("api/v1/books/progress", route("postBookProgress", POST::class.java)?.value)
        assertEquals("api/v1/books/status", route("updateReadStatus", POST::class.java)?.value)
        assertEquals("api/v1/books/{bookId}", route("getBook", GET::class.java)?.value)
    }

    @Test
    fun onlyTheAudiobookProgressReadStillUsesAnAppEndpoint() {
        val appRoutes = GrimmoryApi::class.java.declaredMethods.mapNotNull { method ->
            listOfNotNull(
                method.getAnnotation(GET::class.java)?.value,
                method.getAnnotation(POST::class.java)?.value,
                method.getAnnotation(PUT::class.java)?.value,
                method.getAnnotation(DELETE::class.java)?.value,
            ).firstOrNull { it.startsWith("api/v1/app/") }?.let { method.name to it }
        }
        assertEquals(listOf("getAppBookProgress" to "api/v1/app/books/{bookId}/progress"), appRoutes)
    }

    @Test
    fun browseRequestsSendRepeatedFacetsAndSignedSort() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val api = Retrofit.Builder()
                .baseUrl(server.url("/"))
                .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
                .build()
                .create(GrimmoryApi::class.java)
            server.enqueue(MockResponse().setBody(
                """{"content":[{"id":9,"metadata":{"title":"Nested","authors":["A"]},"primaryFile":{"id":90,"bookType":"EPUB"}}],
                   "page":{"number":1,"size":10,"totalElements":21,"totalPages":3},"links":[{"rel":"next","href":"/next"}]}""",
            ))
            val page = api.getBooksPage(
                facets = listOf("read_status:READING", "read_status:RE_READING", "file_type:AUDIOBOOK", "shelf:magic:4"),
                query = "dune",
                sort = "-lastReadTime",
                page = 1,
                size = 10,
            ).body()!!
            val request = server.takeRequest().requestUrl!!
            assertEquals("/api/v1/books/page", request.encodedPath)
            assertEquals(
                listOf("read_status:READING", "read_status:RE_READING", "file_type:AUDIOBOOK", "shelf:magic:4"),
                request.queryParameterValues("facet"),
            )
            assertEquals("dune", request.queryParameter("query"))
            assertEquals("-lastReadTime", request.queryParameter("sort"))
            assertEquals("Nested", page.content.single().metadata?.title)
            assertEquals(1, page.page.number)
            assertEquals(true, page.page.hasNext)
        }
    }

    @Test
    fun seriesFacetDecodesStringAndArrayRels() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val api = Retrofit.Builder()
                .baseUrl(server.url("/"))
                .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
                .build()
                .create(GrimmoryApi::class.java)
            server.enqueue(MockResponse().setBody(
                """{"links":[{"rel":["self"],"href":"/s"},{"rel":"next","href":"/n"}],
                   "facets":[{"metadata":{"key":"series"},"links":[{"rel":"facet","value":"Dune","properties":{"numberOfItems":6}}]}]}""",
            ))
            val body = api.getSeriesFacet().body()!!
            assertEquals("/api/v1/books/facets/series?page=0&size=100", server.takeRequest().path)
            assertEquals(true, body.hasNext)
            assertEquals("Dune", body.facets.single().links.single().value)
            assertEquals(6L, body.facets.single().links.single().properties?.numberOfItems)
        }
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
