package com.enve.core.listeningposition

import org.junit.Assert.*
import org.junit.Test

class ListeningPositionLinkTest {
    private val message = """{"a":["Antoine de Saint-Exupéry"],"dur":5400000,"isbn":"9782070612758","k":"enve.position","pos":1,"t":"Le \"Petit\" Prince \\ Édition","v":1}"""
    private val payload = ListeningPositionPayload.decode(message)

    @Test fun webLinkRoundTrips() {
        val url = ListeningPositionLink.shareUrl(payload)
        assertTrue(url.startsWith("https://envemedia.com/position/?d="))
        assertFalse(url.substringAfter("?d=").contains('='))
        assertEquals(message, ListeningPositionLink.message("enve-book://position?d=${url.substringAfter("?d=")}"))
    }

    @Test fun matchesIosEncoding() {
        assertEquals(
            "eyJhIjpbIkFudG9pbmUgZGUgU2FpbnQtRXh1cMOpcnkiXSwiZHVyIjo1NDAwMDAwLCJpc2JuIjoiOTc4MjA3MDYxMjc1OCIsImsiOiJlbnZlLnBvc2l0aW9uIiwicG9zIjoxLCJ0IjoiTGUgXCJQZXRpdFwiIFByaW5jZSBcXCDDiWRpdGlvbiIsInYiOjF9",
            ListeningPositionLink.shareUrl(payload).substringAfter("?d="),
        )
    }

    @Test fun appSchemeLinkRoundTrips() {
        val data = ListeningPositionLink.shareUrl(payload).substringAfter("?d=")
        assertEquals(message, ListeningPositionLink.message("enve-book://position?d=$data"))
    }

    @Test fun rejectsOtherLinks() {
        val data = ListeningPositionLink.shareUrl(payload).substringAfter("?d=")
        listOf(
            "enve-book://reader?d=$data",
            "https://example.com/position/?d=$data",
            "https://envemedia.com/position/?d=$data",
            "enve://position?d=$data",
            "enve-book://position",
            "https://envemedia.com/position/",
            "enve-book://position?d=%%%",
        ).forEach { assertNull(it, ListeningPositionLink.message(it)) }
    }
}
