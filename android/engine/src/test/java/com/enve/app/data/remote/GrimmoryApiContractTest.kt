package com.enve.app.data.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.PUT

class GrimmoryApiContractTest {

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
        assertNull(GrimmoryApi::class.java.declaredMethods.firstOrNull {
            it.name == "getReadiumProgress"
        })
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
