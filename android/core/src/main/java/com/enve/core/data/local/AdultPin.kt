package com.enve.core.data.local

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

internal object AdultPin {
    private const val ITERATIONS = 210_000
    private const val KEY_BITS = 256

    fun valid(pin: String): Boolean = pin.length in 4..12 && pin.all { it in '0'..'9' }

    fun create(pin: String): Pair<ByteArray, ByteArray> {
        require(valid(pin))
        val salt = ByteArray(32).also(SecureRandom()::nextBytes)
        return salt to derive(pin, salt)
    }

    fun matches(pin: String, salt: ByteArray, expected: ByteArray): Boolean {
        if (!valid(pin)) return false
        return MessageDigest.isEqual(derive(pin, salt), expected)
    }

    private fun derive(pin: String, salt: ByteArray): ByteArray {
        val chars = pin.toCharArray()
        val spec = PBEKeySpec(chars, salt, ITERATIONS, KEY_BITS)
        return try {
            SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
            chars.fill('\u0000')
        }
    }
}

internal fun pinLockoutMs(failures: Int): Long =
    if (failures < 5) 0L else (60_000L shl (failures - 5).coerceAtMost(11)).coerceAtMost(86_400_000L)
