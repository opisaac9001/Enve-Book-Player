package com.enve.core.data.local

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class AdultPinTest {
    @Test fun acceptsOnlyFourToTwelveAsciiDigits() {
        assertTrue(AdultPin.valid("1234"))
        assertTrue(AdultPin.valid("123456789012"))
        listOf("123", "1234567890123", "12a4", "１２３４", "١٢٣٤", " 1234").forEach {
            assertFalse(AdultPin.valid(it))
        }
    }

    @Test fun hashMatchesOnlyTheOriginalPin() {
        val (salt, hash) = AdultPin.create("291746")
        assertTrue(AdultPin.matches("291746", salt, hash))
        assertFalse(AdultPin.matches("291745", salt, hash))
        assertFalse(AdultPin.matches("not digits", salt, hash))
        assertFalse(hash.contentEquals(AdultPin.create("291746").second))
    }

    @Test fun lockoutGrowsAndCaps() {
        assertEquals(0L, pinLockoutMs(4))
        assertEquals(60_000L, pinLockoutMs(5))
        assertEquals(120_000L, pinLockoutMs(6))
        assertEquals(86_400_000L, pinLockoutMs(100))
    }
}
