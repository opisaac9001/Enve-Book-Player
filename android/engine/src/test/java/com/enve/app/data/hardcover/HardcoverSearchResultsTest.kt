package com.enve.app.data.hardcover

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HardcoverSearchResultsTest {
    @Test
    fun typesenseDocumentIdsAreNumericStrings() {
        val results = Json.parseToJsonElement(
            """{"facet_counts":[],"found":2,"hits":[{"document":{"id":"328491","title":"Dune","author_names":["Frank Herbert"],"image":{"url":"https://assets.hardcover.app/edition/1/cover.jpg","color":"#b8a37c","width":400,"height":600},"release_year":1965,"users_count":9000},"highlight":{},"text_match":578730123365711993},{"document":{"id":"7","title":"Untitled Draft","author_names":[],"image":{}}}],"out_of":1000000,"page":1,"request_params":{"per_page":20,"q":"dune"},"search_time_ms":4}"""
        )

        val books = hardcoverBookSearchResults(results)

        assertEquals(328491, books[0].id)
        assertEquals("Dune", books[0].title)
        assertEquals("Frank Herbert", books[0].author)
        assertEquals("https://assets.hardcover.app/edition/1/cover.jpg", books[0].coverUrl)
        assertEquals(1965, books[0].releaseYear)
        assertEquals(7, books[1].id)
        assertNull(books[1].author)
        assertNull(books[1].coverUrl)
        assertNull(books[1].releaseYear)
    }
}
