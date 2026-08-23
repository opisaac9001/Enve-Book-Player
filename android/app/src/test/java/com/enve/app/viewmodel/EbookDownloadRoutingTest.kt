package com.enve.app.viewmodel

import com.enve.core.data.model.BookSource
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class EbookDownloadRoutingTest {

    @Test
    fun storytellerNeverCallsLegacyFallback() {
        var legacyCalled = false

        assertThrows(IllegalStateException::class.java) {
            runBlocking {
                sourceOwnedEbookDownloadUrl(BookSource.STORYTELLER, providerUrl = null) {
                    legacyCalled = true
                    "legacy"
                }
            }
        }

        assertFalse(legacyCalled)
    }

    @Test
    fun grimmoryRetainsLegacyFallback() = runBlocking {
        val result = sourceOwnedEbookDownloadUrl(BookSource.GRIMMORY, providerUrl = null) { "legacy" }

        assertEquals("legacy", result)
    }
}
