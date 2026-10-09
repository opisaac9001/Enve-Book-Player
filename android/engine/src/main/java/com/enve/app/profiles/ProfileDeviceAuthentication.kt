package com.enve.app.profiles

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import dagger.hilt.android.qualifiers.ApplicationContext
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ProfileDeviceAuthentication @Inject constructor(@ApplicationContext context: Context) {
    private val keyguard = checkNotNull(context.getSystemService(KeyguardManager::class.java))
    private var requestedAt: Long? = null

    fun requireRecoveryAvailable() {
        check(keyguard.isDeviceSecure) { "Set a device screen lock before enabling a parent PIN." }
        key()
    }

    @Suppress("DEPRECATION")
    @Synchronized
    fun recoveryIntent(): Intent? {
        if (!keyguard.isDeviceSecure) return null
        key()
        return keyguard.createConfirmDeviceCredentialIntent("Reset parent PIN", "Confirm your device screen lock.")
            ?.also { requestedAt = SystemClock.elapsedRealtime() }
    }

    @Synchronized
    fun verifyRecovery() {
        val started = checkNotNull(requestedAt) { "Start device authentication before resetting the PIN." }
        check(SystemClock.elapsedRealtime() - started in 0L..120_000L) { "Device authentication expired." }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.doFinal(ByteArray(32).also(SecureRandom()::nextBytes))
        requestedAt = null
    }

    @Suppress("DEPRECATION")
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(
                KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setUserAuthenticationRequired(true)
                    .setUserAuthenticationValidityDurationSeconds(30)
                    .setInvalidatedByBiometricEnrollment(false)
                    .build(),
            )
        }.generateKey()
    }

    private companion object {
        const val KEY_ALIAS = "enve.family-profiles.pin-recovery"
    }
}
