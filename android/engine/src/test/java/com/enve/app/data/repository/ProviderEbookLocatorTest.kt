package com.enve.app.data.repository

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.*
import org.junit.Test

class ProviderEbookLocatorTest {
    @Test fun removesOnlyLocalSharedPositionMetadataBeforeTransport() {
        val original = """{"page":5,"enveSharedPosition":true,"locations":{"totalProgression":0.25},"other":"retained"}"""
        val result = Json.parseToJsonElement(providerEbookLocator(original)!!) as JsonObject
        val expected = Json.parseToJsonElement(original) as JsonObject
        assertEquals(JsonObject(expected - "enveSharedPosition"), result)
        assertFalse(result.containsKey("enveSharedPosition"))
    }

    @Test fun unmarkedLocatorsRemainByteForByteUnchanged() {
        val original = """{ "page": 5, "locations": { "totalProgression": 0.25 } }"""
        assertEquals(original, providerEbookLocator(original))
        assertEquals("cbz-page:5", providerEbookLocator("cbz-page:5"))
        assertNull(providerEbookLocator(null))
    }
}
