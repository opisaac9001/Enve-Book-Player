package com.enve.app.data.backup

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.Base64
import javax.crypto.AEADBadTagException

class SettingsTransferWireTest {
    @Test
    fun opensSwiftEnvelopeWithUnicodePassphrase() {
        val payload = """
            {"format":"enve-settings-backup","payload":"FBUWFxgZGhscHR4fb3OmDwDdLA+44aA+K51+l8fepWTr6k9PI1Jkp9U5W4gdSXcNh8x0faFIrwOOMrstU+bc2FKt1w75juX+oVVp9xOvF28=","salt":"AAECAwQFBgcICQoLDA0ODw==","version":1}
        """.trimIndent().encodeToByteArray()
        assertEquals(
            """{"sources":[],"sharedSettings":{"themeMode":"DARK"}}""",
            SettingsTransferWire.open(payload, "re\u0301sume\u0301 portable fixture").decodeToString(),
        )
    }

    @Test
    fun rejectsIncorrectPassphrase() {
        val encrypted = SettingsTransferWire.seal("fixture".encodeToByteArray(), "test-only passphrase")
        assertThrows(AEADBadTagException::class.java) { SettingsTransferWire.open(encrypted, "not the passphrase") }
    }

    @Test
    fun pairingOnlyAcceptsPrivateNumericAddressesAndKeysOfExpectedLength() {
        val key = ByteArray(32) { it.toByte() }
        val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(key)
        val valid = SettingsTransferWire.parse("enve-settings:1:192.168.2.4:49152:$encoded")
        assertEquals("192.168.2.4", valid.host)
        assertEquals(49152, valid.port)
        assertArrayEquals(key, valid.key)
        listOf("localhost", "127.0.0.1", "8.8.8.8", "192.168.000.4").forEach {
            assertThrows(IllegalArgumentException::class.java) { SettingsTransferWire.parse("enve-settings:1:$it:49152:$encoded") }
        }
        assertThrows(IllegalArgumentException::class.java) { SettingsTransferWire.parse("enve-settings:1:192.168.2.4:0:$encoded") }
    }
}
