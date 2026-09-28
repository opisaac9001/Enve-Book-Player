package com.enve.app.data.opds

import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsCredentialScopeTest {

    private val catalog = connection("conn-1", BookSource.OPDS, "https://opds.example.com/v1")
    private val otherCatalog = connection("conn-2", BookSource.OPDS, "http://192.168.1.4:8080/opds")
    private val komga = connection("conn-3", BookSource.KOMGA, "https://komga.example.com")

    @Test
    fun a_scoped_connection_signs_only_its_own_origin() {
        assertTrue(opdsCredentialsAllowed(catalog, emptyList(), "https://opds.example.com/fiction?page=2"))
        assertTrue(opdsCredentialsAllowed(catalog, emptyList(), "https://opds.example.com:443/search"))
        assertFalse(opdsCredentialsAllowed(catalog, emptyList(), "https://evil.example.org/opensearch.xml"))
        assertFalse(opdsCredentialsAllowed(catalog, emptyList(), "https://opds.example.com:8443/fiction"))
        assertFalse(opdsCredentialsAllowed(catalog, emptyList(), "http://opds.example.com/fiction"))
    }

    @Test
    fun an_unscoped_request_is_signed_only_for_a_configured_opds_origin() {
        val configured = listOf(catalog, otherCatalog, komga)

        assertTrue(opdsCredentialsAllowed(null, configured, "https://opds.example.com/cover.jpg"))
        assertTrue(opdsCredentialsAllowed(null, configured, "http://192.168.1.4:8080/cover.jpg"))
        assertFalse(opdsCredentialsAllowed(null, configured, "https://komga.example.com/cover.jpg"))
        assertFalse(opdsCredentialsAllowed(null, configured, "https://evil.example.org/cover.jpg"))
    }

    @Test
    fun a_request_with_no_resolvable_origin_is_never_signed() {
        assertFalse(opdsCredentialsAllowed(catalog, emptyList(), "/fiction"))
        assertFalse(opdsCredentialsAllowed(null, listOf(catalog), "not a url"))
        assertFalse(opdsCredentialsAllowed(null, emptyList(), "https://opds.example.com/fiction"))
        assertFalse(
            opdsCredentialsAllowed(catalog.copy(serverUrl = ""), emptyList(), "https://opds.example.com/fiction"),
        )
    }

    private fun connection(id: String, source: BookSource, serverUrl: String) = ProviderConnection(
        id = id,
        source = source,
        name = id,
        serverUrl = serverUrl,
        username = "reader",
    )
}
