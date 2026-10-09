package com.enve.wear.listening

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

@Serializable
data class WatchAccount(
    val server: String,
    val userId: String,
    val username: String,
    val token: String,
    val refreshToken: String? = null,
    val source: WatchSource = WatchSource.AUDIOBOOKSHELF,
) {
    val key: String get() = storageKey("${source.name}/$server/$userId")
}

@Serializable
private data class WatchAccounts(
    val activeKey: String? = null,
    val accounts: List<WatchAccount> = emptyList(),
)

class CredentialVault(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "watch-session"))

    fun read(): WatchAccount? = synchronized(lock) {
        val payload = readPayload()
        payload.accounts.firstOrNull { it.key == payload.activeKey } ?: payload.accounts.firstOrNull()
    }

    fun read(key: String): WatchAccount? = synchronized(lock) {
        readPayload().accounts.firstOrNull { it.key == key }
    }

    fun all(): List<WatchAccount> = synchronized(lock) { readPayload().accounts }

    fun write(account: WatchAccount) = synchronized(lock) {
        val current = readPayload()
        writePayload(current.copy(
            activeKey = account.key,
            accounts = current.accounts.filterNot { it.key == account.key } + account,
        ))
    }

    fun updateIfCurrent(expected: WatchAccount, updated: WatchAccount): Boolean = synchronized(lock) {
        val current = readPayload()
        if (current.accounts.firstOrNull { it.key == expected.key } != expected || updated.key != expected.key) return@synchronized false
        writePayload(current.copy(accounts = current.accounts.map { if (it.key == expected.key) updated else it }))
        true
    }

    fun select(key: String): Boolean = synchronized(lock) {
        val current = readPayload()
        if (current.accounts.none { it.key == key }) return@synchronized false
        writePayload(current.copy(activeKey = key))
        true
    }

    fun remove(key: String) = synchronized(lock) {
        val current = readPayload()
        val remaining = current.accounts.filterNot { it.key == key }
        writePayload(WatchAccounts(
            activeKey = current.activeKey?.takeIf { it != key } ?: remaining.firstOrNull()?.key,
            accounts = remaining,
        ))
    }

    fun clear() = synchronized(lock) { file.delete() }

    private fun readPayload(): WatchAccounts {
        if (!file.baseFile.exists()) return WatchAccounts()
        return try {
            val bytes = file.readFully()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            val decoded = cipher.doFinal(bytes.copyOfRange(12, bytes.size)).decodeToString()
            runCatching { Json.decodeFromString<WatchAccounts>(decoded) }
                .getOrElse { WatchAccounts(accounts = listOf(Json.decodeFromString<WatchAccount>(decoded))) }
        } catch (_: Exception) {
            file.delete()
            WatchAccounts()
        }
    }

    private fun writePayload(accounts: WatchAccounts) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val output = file.startWrite()
        try {
            output.write(cipher.iv + cipher.doFinal(Json.encodeToString(accounts).toByteArray()))
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    companion object {
        private const val ALIAS = "enve-watch-session"
        private val lock = Any()
    }
}
