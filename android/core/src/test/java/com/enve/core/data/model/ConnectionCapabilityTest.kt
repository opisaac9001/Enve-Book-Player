package com.enve.core.data.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionCapabilityTest {
    @Test
    fun grimmoryRequiresRenewableAuthentication() {
        val capability = ConnectionCapability.forSource(BookSource.GRIMMORY)

        assertTrue(capability.supportsUsernamePassword)
        assertTrue(capability.supportsOidc)
        assertFalse(capability.supportsToken)
    }

    @Test
    fun permanentTokenProvidersStillSupportTokens() {
        assertTrue(ConnectionCapability.forSource(BookSource.PLEX).supportsToken)
        assertTrue(ConnectionCapability.forSource(BookSource.TORBOX).supportsToken)
    }
}
