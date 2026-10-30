package com.enve.hearth.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class LibraryRefreshErrorTest {
    @Test
    fun presentsHttpStatusWithoutServerResponseDetails() {
        val message = libraryRefreshErrorMessage("Jellyfin item loading failed: HTTP 400; private-fixture-detail")
        assertEquals("The server returned HTTP 400. Check your source connection and try again.", message)
        assertFalse(message.contains("private-fixture-detail"))
    }

    @Test
    fun networkFailuresDoNotExposeAddressesTokensOrCredentials() {
        val error = "Failed to connect to https://fixture-user:fixture-password@jellyfin.test:8096/?api_key=fixture-token"
        assertEquals("Check your source connection and try again.", libraryRefreshErrorMessage(error))
    }
}
