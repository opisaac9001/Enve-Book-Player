package com.enve.app.data.discover

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DiscoverRepositoryTest {

    @Test
    fun decodeGoogleBooksResponse_maps_public_metadata() {
        val response = """
            {
              "items": [
                {
                  "id": "volume-1",
                  "volumeInfo": {
                    "title": "The Way of Kings",
                    "subtitle": "The Stormlight Archive",
                    "authors": ["Brandon Sanderson"],
                    "publishedDate": "2010-08-31",
                    "description": "<p>Epic fantasy&nbsp;with storms.</p>",
                    "industryIdentifiers": [
                      { "type": "ISBN_10", "identifier": "0765326353" },
                      { "type": "ISBN_13", "identifier": "9780765326355" }
                    ],
                    "pageCount": 1007,
                    "categories": ["Fiction / Fantasy / Epic"],
                    "imageLinks": {
                      "smallThumbnail": "http://books.google.com/small.jpg",
                      "thumbnail": "http://books.google.com/thumb.jpg"
                    },
                    "previewLink": "http://books.google.com/preview",
                    "infoLink": "http://books.google.com/info"
                  }
                }
              ]
            }
        """.trimIndent()

        val book = decodeGoogleBooksResponse(response).single()

        assertEquals("volume-1", book.id)
        assertEquals("The Way of Kings: The Stormlight Archive", book.title)
        assertEquals("Brandon Sanderson", book.author)
        assertEquals("https://books.google.com/thumb.jpg", book.secureArtworkUrl)
        assertEquals("Epic fantasy with storms.", book.description)
        assertEquals("2010-08-31", book.publishedDate)
        assertEquals("Fiction / Fantasy / Epic", book.genre)
        assertEquals(1007, book.pageCount)
        assertEquals("https://books.google.com/preview", book.previewUrl)
        assertEquals("https://books.google.com/info", book.infoUrl)
        assertEquals("9780765326355", book.collectionId)
    }

    @Test
    fun decodeGoogleBooksResponse_skips_items_without_titles() {
        val response = """
            {
              "items": [
                { "id": "missing", "volumeInfo": { "authors": ["Author"] } },
                { "id": "valid", "volumeInfo": { "title": "Real Book" } }
              ]
            }
        """.trimIndent()

        val books = decodeGoogleBooksResponse(response)

        assertEquals(1, books.size)
        assertEquals("Real Book", books.single().title)
    }

    @Test
    fun decodeAudibleCatalogResponse_maps_audiobook_metadata() {
        val response = """
            {
              "products": [
                {
                  "asin": "B08G9PRS1K",
                  "title": "Project Hail Mary",
                  "subtitle": "A Novel",
                  "authors": [{ "name": "Andy Weir" }],
                  "narrators": [{ "name": "Ray Porter" }],
                  "runtime_length_min": 966,
                  "release_date": "2021-05-04",
                  "publication_datetime": "2021-05-04T07:00:00Z",
                  "product_images": {
                    "500": "http://m.media-amazon.com/images/I/cover._SL500_.jpg",
                    "1024": "https://m.media-amazon.com/images/I/cover._SL1024_.jpg"
                  },
                  "publisher_summary": "<p>A lone astronaut&nbsp;must save Earth.</p>",
                  "category_ladders": [
                    {
                      "root": "Genres",
                      "ladder": [
                        { "name": "Science Fiction & Fantasy" },
                        { "name": "Science Fiction" }
                      ]
                    }
                  ]
                }
              ]
            }
        """.trimIndent()

        val book = decodeAudibleCatalogResponse(response).single()

        assertEquals("audible-B08G9PRS1K", book.id)
        assertEquals("Project Hail Mary: A Novel", book.title)
        assertEquals("Andy Weir", book.author)
        assertEquals("https://m.media-amazon.com/images/I/cover._SL1024_.jpg", book.secureArtworkUrl)
        assertEquals("A lone astronaut must save Earth.", book.description)
        assertEquals("2021-05-04", book.publishedDate)
        assertEquals("Science Fiction", book.genre)
        assertNull(book.pageCount)
        assertEquals(57_960_000L, book.durationMillis)
        assertEquals("16h 6m", book.displayRuntime)
        assertNull(book.previewUrl)
        assertEquals("https://www.audible.com/pd/B08G9PRS1K", book.infoUrl)
        assertEquals("B08G9PRS1K", book.collectionId)
    }

    @Test
    fun decodeAudibleCatalogResponse_skips_items_without_asin_or_title() {
        val response = """
            {
              "products": [
                { "title": "Missing ASIN" },
                { "asin": "B000000000" },
                { "asin": "B111111111", "title": "Valid Book" }
              ]
            }
        """.trimIndent()

        val books = decodeAudibleCatalogResponse(response)

        assertEquals(1, books.size)
        assertEquals("Valid Book", books.single().title)
    }

    @Test
    fun decodeItunesAudiobookResponse_maps_audiobook_metadata() {
        val response = """
            {
              "resultCount": 1,
              "results": [
                {
                  "collectionId": 12345,
                  "collectionName": "Project Hail Mary (Unabridged)",
                  "artistName": "Andy Weir",
                  "artworkUrl100": "http://is1-ssl.mzstatic.com/image/thumb/Audio115/v4/cover/100x100bb.jpg",
                  "description": "<p>A lone astronaut must save Earth.</p>",
                  "releaseDate": "2021-05-04T07:00:00Z",
                  "primaryGenreName": "Sci-Fi & Fantasy",
                  "trackTimeMillis": 57960000,
                  "previewUrl": "http://audio.itunes.apple.com/preview.m4a",
                  "collectionViewUrl": "http://books.apple.com/us/audiobook/project-hail-mary/id12345"
                }
              ]
            }
        """.trimIndent()

        val book = decodeItunesAudiobookResponse(response).single()

        assertEquals("12345", book.id)
        assertEquals("Project Hail Mary (Unabridged)", book.title)
        assertEquals("Andy Weir", book.author)
        assertEquals("https://is1-ssl.mzstatic.com/image/thumb/Audio115/v4/cover/600x600bb.jpg", book.secureArtworkUrl)
        assertEquals("A lone astronaut must save Earth.", book.description)
        assertEquals("2021-05-04T07:00:00Z", book.publishedDate)
        assertEquals("Sci-Fi & Fantasy", book.genre)
        assertEquals(57_960_000L, book.durationMillis)
        assertEquals("16h 6m", book.displayRuntime)
        assertEquals("https://audio.itunes.apple.com/preview.m4a", book.previewUrl)
        assertEquals("https://books.apple.com/us/audiobook/project-hail-mary/id12345", book.infoUrl)
        assertEquals("12345", book.collectionId)
    }

    @Test
    fun deduplicatedDiscoverBooks_prefers_isbn_identity() {
        val books = listOf(
            discoverBook(id = "a", title = "Dune", author = "Frank Herbert", collectionId = "9780441172719"),
            discoverBook(id = "b", title = "Dune Deluxe", author = "Frank Herbert", collectionId = "9780441172719"),
            discoverBook(id = "c", title = "Dune Messiah", author = "Frank Herbert", collectionId = "9780593098233"),
        )

        val deduped = books.deduplicatedDiscoverBooks()

        assertEquals(listOf("a", "c"), deduped.map { it.id })
    }

    @Test
    fun deduplicatedDiscoverBooks_falls_back_to_normalized_title_and_author() {
        val books = listOf(
            discoverBook(id = "a", title = "The Hobbit", author = "J. R. R. Tolkien", collectionId = null),
            discoverBook(id = "b", title = "The Hobbit!", author = "J.R.R. Tolkien", collectionId = null),
            discoverBook(id = "c", title = "The Silmarillion", author = "J. R. R. Tolkien", collectionId = null),
        )

        val deduped = books.deduplicatedDiscoverBooks()

        assertEquals(listOf("a", "c"), deduped.map { it.id })
    }

    @Test
    fun displayYear_returns_null_for_partial_or_malformed_dates() {
        assertEquals("2026", discoverBook(publishedDate = "2026-03-01").displayYear)
        assertNull(discoverBook(publishedDate = "Soon").displayYear)
        assertNull(discoverBook(publishedDate = "20").displayYear)
    }

    private fun discoverBook(
        id: String = "id",
        title: String = "Title",
        author: String? = "Author",
        collectionId: String? = "collection",
        publishedDate: String? = null,
    ): DiscoverBook =
        DiscoverBook(
            id = id,
            title = title,
            author = author,
            artworkUrl = null,
            description = null,
            publishedDate = publishedDate,
            genre = null,
            pageCount = null,
            durationMillis = null,
            previewUrl = null,
            infoUrl = null,
            collectionId = collectionId,
        )
}
