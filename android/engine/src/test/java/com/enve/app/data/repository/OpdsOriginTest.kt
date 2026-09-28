package com.enve.app.data.repository

import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsOriginTest {

    private val root = "https://opds.example.com/v1/catalog"

    @Test
    fun an_origin_is_normalised_to_its_scheme_host_and_effective_port() {
        assertEquals("https://opds.example.com:443", opdsOrigin("https://opds.example.com/root"))
        assertEquals("https://opds.example.com:443", opdsOrigin("HTTPS://OPDS.Example.COM/root"))
        assertEquals("https://opds.example.com:443", opdsOrigin("https://opds.example.com:443/root"))
        assertEquals("http://opds.example.com:80", opdsOrigin("http://opds.example.com/root"))
        assertEquals("http://opds.example.com:8080", opdsOrigin("http://opds.example.com:8080/root"))
    }

    @Test
    fun anything_that_is_not_an_absolute_http_url_has_no_origin() {
        assertNull(opdsOrigin("/fiction"))
        assertNull(opdsOrigin("fiction"))
        assertNull(opdsOrigin("//opds.example.com/fiction"))
        assertNull(opdsOrigin("ftp://opds.example.com/fiction"))
        assertNull(opdsOrigin("javascript:alert(1)"))
        assertNull(opdsOrigin(""))
    }

    @Test
    fun the_default_port_spelling_is_the_same_origin_and_another_port_is_not() {
        assertTrue(isSameOpdsOrigin(root, "https://opds.example.com:443/fiction"))
        assertTrue(isSameOpdsOrigin("https://opds.example.com:443/v1", "https://opds.example.com/fiction"))
        assertFalse(isSameOpdsOrigin(root, "https://opds.example.com:8443/fiction"))
        assertFalse(isSameOpdsOrigin(root, "http://opds.example.com/fiction"))
        assertFalse(isSameOpdsOrigin(root, "https://evil.example.org/fiction"))
    }

    @Test
    fun an_unusable_url_on_either_side_fails_closed() {
        assertFalse(isSameOpdsOrigin(null, "https://opds.example.com/fiction"))
        assertFalse(isSameOpdsOrigin("", "https://opds.example.com/fiction"))
        assertFalse(isSameOpdsOrigin("not a url", "https://opds.example.com/fiction"))
        assertFalse(isSameOpdsOrigin(root, "/fiction"))
        assertFalse(isSameOpdsOrigin(root, "not a url"))
    }

    @Test
    fun a_laundered_acquisition_url_from_an_old_migration_is_refused_at_runtime() {
        val foreign = cachedBook("https://evil.example.org/a.epub")
        val local = cachedBook("https://opds.example.com/a.epub")

        assertNull(resolveOpdsAcquisitionUrl(foreign, "urn:uuid:1", root))
        assertEquals("https://opds.example.com/a.epub", resolveOpdsAcquisitionUrl(local, "urn:uuid:1", root))
    }

    @Test
    fun a_book_id_is_only_used_as_a_download_url_when_it_stays_on_the_catalog() {
        assertEquals(
            "https://opds.example.com/a.epub",
            resolveOpdsAcquisitionUrl(null, "https://opds.example.com/a.epub", root),
        )
        assertNull(resolveOpdsAcquisitionUrl(null, "https://evil.example.org/a.epub", root))
        assertNull(resolveOpdsAcquisitionUrl(null, "urn:uuid:1", root))
        assertNull(resolveOpdsAcquisitionUrl(null, "https://opds.example.com/a.epub", null))
    }

    private fun cachedBook(acquisitionUrl: String) = Book(
        id = "urn:uuid:1",
        title = "Moby-Dick",
        source = BookSource.OPDS,
        connectionId = "conn-1",
        opdsAcquisitionUrl = acquisitionUrl,
    ).toCachedBook()
}
