package com.enve.core.data.local

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CachedBookOpdsAcquisitionTest {

    private fun opdsBook(acquisitionUrl: String?) = Book(
        id = "urn:uuid:stable-1",
        title = "Persisted",
        source = BookSource.OPDS,
        mediaType = AppMediaType.AUDIOBOOK,
        connectionId = "conn-1",
        opdsAcquisitionUrl = acquisitionUrl,
    )

    @Test
    fun the_acquisition_url_survives_the_cache_round_trip() {
        val url = "https://opds.example.com/books/1/download.m4b"

        val cached = opdsBook(url).toCachedBook(nowMs = 1L)

        assertEquals(url, cached.opdsAcquisitionUrl)
        assertEquals(url, cached.toBook().opdsAcquisitionUrl)
    }

    @Test
    fun a_publication_without_a_direct_acquisition_caches_no_url() {
        val cached = opdsBook(null).toCachedBook(nowMs = 1L)

        assertNull(cached.opdsAcquisitionUrl)
        assertNull(cached.toBook().opdsAcquisitionUrl)
    }
}
