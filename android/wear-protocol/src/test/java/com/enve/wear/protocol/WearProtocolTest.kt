package com.enve.wear.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

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
}
