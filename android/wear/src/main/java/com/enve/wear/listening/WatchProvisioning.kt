package com.enve.wear.listening

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.enve.wear.protocol.WearProtocol
import com.enve.wear.protocol.WearProvisioningCrypto
import com.enve.wear.protocol.WearProvisioningRequest
import com.enve.wear.protocol.WearProvisioningResult
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.PutDataRequest
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.util.UUID
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

class WatchProvisioningManager(private val context: Context) {
    private val preferences = context.getSharedPreferences("watch-provisioning", Context.MODE_PRIVATE)

    fun publishRequest(): WearProvisioningRequest {
        val request = newRequest()
        Wearable.getDataClient(context).putDataItem(PutDataRequest.create(WearProtocol.PROVISIONING_REQUEST_PATH).apply {
            data = WearProtocol.encodeProvisioningRequest(request)
            setUrgent()
        })
        return request
    }

    fun consume(bytes: ByteArray): com.enve.wear.protocol.WearProvisionedConnection {
        val envelope = WearProtocol.decodeProvisioningEnvelope(bytes)
        synchronized(requestLock) {
            val expected = preferences.getString(KEY_REQUEST_ID, null)
            val expiresAt = preferences.getLong(KEY_EXPIRES_AT, 0L)
            if (expected == null || envelope.requestId != expected || System.currentTimeMillis() > expiresAt) {
                throw WatchRequestException("This phone link has expired. Open the watch app and try again.")
            }
            if (!preferences.edit().remove(KEY_REQUEST_ID).remove(KEY_EXPIRES_AT).commit()) {
                throw WatchRequestException("Couldn’t finish linking. Try again.")
            }
        }
        val plaintext = WearProvisioningCrypto.decrypt(privateKey(), envelope)
        return WearProtocol.decodeProvisionedConnection(plaintext)
    }

    private fun newRequest(): WearProvisioningRequest {
        val requestId = UUID.randomUUID().toString()
        val createdAt = System.currentTimeMillis()
        preferences.edit()
            .putString(KEY_REQUEST_ID, requestId)
            .putLong(KEY_EXPIRES_AT, createdAt + REQUEST_LIFETIME_MS)
            .apply()
        return WearProvisioningRequest(requestId, keyStore().getCertificate(ALIAS).publicKey.encoded, createdAt)
    }

    private fun privateKey(): PrivateKey = keyStore().getKey(ALIAS, null) as PrivateKey

    private fun keyStore(): KeyStore {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!store.containsAlias(ALIAS)) {
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore").apply {
                initialize(KeyGenParameterSpec.Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setKeySize(2048)
                    .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA512)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
                    .build())
            }.generateKeyPair()
        }
        return store
    }

    companion object {
        private const val ALIAS = "enve-watch-provisioning"
        private const val KEY_REQUEST_ID = "request-id"
        private const val KEY_EXPIRES_AT = "expires-at"
        private const val REQUEST_LIFETIME_MS = 5 * 60 * 1000L
        private val requestLock = Any()
    }
}

object WatchProvisioningEvents {
    private val mutable = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val events = mutable.asSharedFlow()
    fun accountAdded() { mutable.tryEmit(Unit) }
}

class WatchProvisioningService : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != WearProtocol.PROVISION_CONNECTION_PATH) return
        val manager = WatchProvisioningManager(this)
        val requestId = runCatching {
            WearProtocol.decodeProvisioningEnvelope(event.data).requestId
        }.getOrDefault("")
        val result = try {
            val connection = manager.consume(event.data)
            val source = runCatching { WatchSource.valueOf(connection.source) }
                .getOrElse { throw WatchRequestException("This service is not supported on the watch yet.") }
            if (WatchProviderRegistry(CredentialVault(this)).providerOrNull(source) == null) {
                throw WatchRequestException("${source.displayName} is not supported on the watch yet.")
            }
            val server = when (source) {
                WatchSource.AUDIOBOOKSHELF -> WatchAbsClient.normalizeServer(connection.server).toString()
                WatchSource.GRIMMORY -> WatchGrimmoryClient.normalizeServer(connection.server).toString()
                else -> throw WatchRequestException("${source.displayName} is not supported on the watch yet.")
            }
            val vault = CredentialVault(this)
            val account = WatchAccount(
                server = server,
                userId = connection.connectionId,
                username = connection.username,
                token = connection.accessToken,
                refreshToken = connection.refreshToken,
                source = source,
            )
            vault.all()
                .filter { it.source == source && it.userId == connection.connectionId && it.key != account.key }
                .forEach { vault.remove(it.key) }
            vault.write(account)
            WatchProvisioningEvents.accountAdded()
            manager.publishRequest()
            WearProvisioningResult(requestId, success = true)
        } catch (error: Exception) {
            manager.publishRequest()
            WearProvisioningResult(
                requestId = requestId,
                success = false,
                message = if (error is WatchRequestException) error.message else null,
            )
        }
        Wearable.getMessageClient(this).sendMessage(
            event.sourceNodeId,
            WearProtocol.PROVISIONING_RESULT_PATH,
            WearProtocol.encodeProvisioningResult(result),
        )
    }
}
