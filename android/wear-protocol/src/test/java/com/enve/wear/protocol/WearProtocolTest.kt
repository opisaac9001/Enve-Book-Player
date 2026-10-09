package com.enve.wear.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.security.KeyPairGenerator

class WearProtocolTest {
    @Test
    fun stateRoundTrips() {
        val state = WearState(
            hasMedia = true,
            title = "North Woods",
            recentBooks = listOf(WearBook("local:1", "North Woods", "Daniel Mason", 0.42f)),
            sleepRemainingSec = 1_800,
            lastSleepMs = 25_200_000,
        )

        assertEquals(state, WearProtocol.decode(WearProtocol.encode(state)))
    }

    @Test
    fun decoderIgnoresFieldsFromNewerPhoneVersions() {
        val state = WearProtocol.decode("""{"title":"A Book","future":true}""".encodeToByteArray())

        assertEquals("A Book", state.title)
        assertEquals(false, state.hasMedia)
    }

    @Test
    fun provisionedConnectionIsEncryptedForOneWatchRequest() {
        val keys = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val connection = WearProvisionedConnection(
            connectionId = "connection-id",
            source = "AUDIOBOOKSHELF",
            server = "https://books.example.com/",
            username = "reader",
            accessToken = "access-token",
            refreshToken = "refresh-token",
        )
        val plaintext = WearProtocol.encodeProvisionedConnection(connection)
        val envelope = WearProvisioningCrypto.encrypt(keys.public.encoded, "request-one", plaintext)

        val decoded = WearProtocol.decodeProvisionedConnection(WearProvisioningCrypto.decrypt(keys.private, envelope))
        assertEquals(connection, decoded)
        assertEquals(false, WearProtocol.encodeProvisioningEnvelope(envelope).decodeToString().contains("access-token"))
    }

    @Test
    fun provisioningRequestCannotBeChangedAfterEncryption() {
        val keys = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val envelope = WearProvisioningCrypto.encrypt(keys.public.encoded, "request-one", "secret".encodeToByteArray())

        assertThrows(Exception::class.java) {
            WearProvisioningCrypto.decrypt(keys.private, envelope.copy(requestId = "request-two"))
        }
    }

    @Test
    fun provisioningResultRoundTrips() {
        val result = WearProvisioningResult(
            requestId = "request-one",
            success = false,
            message = "Try again.",
        )

        assertEquals(result, WearProtocol.decodeProvisioningResult(WearProtocol.encodeProvisioningResult(result)))
    }
}
