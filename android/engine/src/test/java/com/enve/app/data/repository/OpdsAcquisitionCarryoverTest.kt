package com.enve.app.data.repository

import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsAcquisitionCarryoverTest {

    private val acquisitionUrl = "https://opds.example.com/books/1/download.epub"
    private val serverUrl = "https://opds.example.com/opds"

    private fun cached(
        id: String,
        opdsAcquisitionUrl: String? = null,
        readProgress: Float = 0f,
        currentTime: Long = 0L,
        epubLocator: String? = null,
        lastReadTime: Long = 0L,
    ) = Book(
        id = id,
        title = id,
        source = BookSource.OPDS,
        mediaType = AppMediaType.EBOOK,
        connectionId = "conn-1",
        readProgress = readProgress,
        epubProgress = readProgress,
        epubLocator = epubLocator,
        currentTime = currentTime,
        lastReadTime = lastReadTime,
        opdsAcquisitionUrl = opdsAcquisitionUrl,
    ).toCachedBook(nowMs = 1_000L)

    @Test
    fun a_refreshed_stable_row_points_at_the_legacy_url_keyed_row() {
        val stable = cached(id = "urn:stable", opdsAcquisitionUrl = acquisitionUrl)

        assertEquals("conn-1:$acquisitionUrl", stable.supersededCacheKey())
    }

    @Test
    fun a_row_whose_id_is_already_the_acquisition_url_supersedes_nothing() {
        assertNull(cached(id = acquisitionUrl, opdsAcquisitionUrl = acquisitionUrl).supersededCacheKey())
        assertNull(cached(id = "urn:stable").supersededCacheKey())
    }

    @Test
    fun local_progress_carries_from_the_legacy_row_into_the_stable_row() {
        val legacy = cached(
            id = acquisitionUrl,
            opdsAcquisitionUrl = acquisitionUrl,
            readProgress = 0.42f,
            currentTime = 90L,
            epubLocator = """{"href":"/ch2"}""",
            lastReadTime = 5_000L,
        )
        val refreshed = cached(id = "urn:stable", opdsAcquisitionUrl = acquisitionUrl)

        val merged = refreshed.preservingLocalProgress(legacy)

        assertEquals("urn:stable", merged.id)
        assertEquals("conn-1:urn:stable", merged.cacheKey)
        assertEquals(acquisitionUrl, merged.opdsAcquisitionUrl)
        assertEquals(0.42f, merged.readProgress, 0.0001f)
        assertEquals(0.42f, merged.epubProgress ?: 0f, 0.0001f)
        assertEquals(90L, merged.currentTime)
        assertEquals("""{"href":"/ch2"}""", merged.epubLocator)
        assertEquals(5_000L, merged.lastReadTime)
        assertTrue(merged.inProgress)
    }

    @Test
    fun a_cold_start_resolves_the_download_url_from_the_persisted_column() {
        val stable = cached(id = "urn:stable", opdsAcquisitionUrl = acquisitionUrl)

        assertEquals(acquisitionUrl, resolveOpdsAcquisitionUrl(stable, stable.id, serverUrl))
        assertEquals(acquisitionUrl, resolveOpdsAcquisitionUrl(null, acquisitionUrl, serverUrl))
        assertNull(resolveOpdsAcquisitionUrl(null, "urn:stable", serverUrl))
        assertNull(resolveOpdsAcquisitionUrl(cached(id = "urn:unsupported"), "urn:unsupported", serverUrl))
    }

    @Test
    fun an_identifier_that_points_off_the_catalog_origin_is_not_a_download_url() {
        assertNull(resolveOpdsAcquisitionUrl(null, "https://attacker.example/steal.epub", serverUrl))
        assertNull(resolveOpdsAcquisitionUrl(null, acquisitionUrl, null))
        assertEquals(
            acquisitionUrl,
            resolveOpdsAcquisitionUrl(null, acquisitionUrl, "https://opds.example.com"),
        )
    }
}
