package com.enve.app.data.repository.grimmory

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GrimmoryCatalogFallbackTest {

    @Test
    fun `successful populated app response stays on app catalog`() {
        assertFalse(shouldUseLegacyGrimmoryCatalog(responseCode = 200, firstPageItemCount = 12))
    }

    @Test
    fun `successful empty app response falls back to legacy catalog`() {
        assertTrue(shouldUseLegacyGrimmoryCatalog(responseCode = 200, firstPageItemCount = 0))
    }

    @Test
    fun `successful response without a decodable body falls back to legacy catalog`() {
        assertTrue(shouldUseLegacyGrimmoryCatalog(responseCode = 200, firstPageItemCount = null))
    }

    @Test
    fun `unsupported and failed app endpoints fall back to legacy catalog`() {
        listOf(401, 403, 404, 405, 500, 501).forEach { responseCode ->
            assertTrue(
                "Expected HTTP $responseCode to use the legacy catalog",
                shouldUseLegacyGrimmoryCatalog(responseCode, firstPageItemCount = null),
            )
        }
    }
}
