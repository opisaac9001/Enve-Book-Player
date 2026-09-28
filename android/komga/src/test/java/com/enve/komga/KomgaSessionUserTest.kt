package com.enve.komga

import org.junit.Assert.assertEquals
import org.junit.Test

class KomgaSessionUserTest {
    @Test
    fun v2UsersMeResolvesTheLoginEmail() {
        val body = """
            {"id":"0R9AMY3ADMMDZ","email":"reader@example.invalid","roles":["ADMIN","FILE_DOWNLOAD","KOBO_SYNC","KOREADER_SYNC","PAGE_STREAMING","USER"],"sharedAllLibraries":true,"sharedLibrariesIds":[],"labelsAllow":[],"labelsExclude":[]}
        """.trimIndent()

        assertEquals("reader@example.invalid", komgaSessionEmail(body))
    }

    @Test(expected = kotlinx.serialization.SerializationException::class)
    fun nonUserBodyIsNotAcceptedAsAVerifiedSession() {
        komgaSessionEmail("""{"timestamp":"2026-09-26T05:21:13.020+00:00","status":404,"error":"Not Found"}""")
    }
}
