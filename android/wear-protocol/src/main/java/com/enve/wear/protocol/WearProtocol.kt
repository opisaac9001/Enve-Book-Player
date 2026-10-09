package com.enve.wear.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.GCMParameterSpec

@Serializable
data class WearBook(
    val key: String,
    val title: String,
    val author: String? = null,
    val progress: Float = 0f,
)

@Serializable
data class WearState(
    val hasMedia: Boolean = false,
    val isPlaying: Boolean = false,
    val title: String? = null,
    val author: String? = null,
    val positionMs: Long = 0L,
    val durationMs: Long = 0L,
    val speed: Float = 1f,
    val sleepRemainingSec: Long? = null,
    val recentBooks: List<WearBook> = emptyList(),
    val lastSleepMs: Long? = null,
    val averageSleepMs: Long? = null,
    val sleepNights: Int = 0,
    val updatedAtMs: Long = 0L,
)

@Serializable
data class WearProvisioningRequest(
    val requestId: String,
    val publicKey: ByteArray,
    val createdAtMs: Long,
)

@Serializable
data class WearProvisionedConnection(
    val connectionId: String,
    val source: String,
    val server: String,
    val username: String,
    val accessToken: String,
    val refreshToken: String? = null,
)

@Serializable
data class WearProvisioningEnvelope(
    val requestId: String,
    val encryptedKey: ByteArray,
    val nonce: ByteArray,
    val ciphertext: ByteArray,
)

@Serializable
data class WearProvisioningResult(
    val requestId: String,
    val success: Boolean,
    val message: String? = null,
)

object WearProtocol {
    const val STATE_PATH = "/enve/state"
    const val REQUEST_STATE_PATH = "/enve/state/request"
    const val TOGGLE_PATH = "/enve/playback/toggle"
    const val BACK_PATH = "/enve/playback/back"
    const val FORWARD_PATH = "/enve/playback/forward"
    const val OPEN_BOOK_PATH = "/enve/playback/open"
    const val START_SLEEP_PATH = "/enve/sleep/start"
    const val CANCEL_SLEEP_PATH = "/enve/sleep/cancel"
    const val PROVISIONING_REQUEST_PATH = "/enve/provisioning/request"
    const val PROVISION_CONNECTION_PATH = "/enve/provisioning/connection"
    const val PROVISIONING_RESULT_PATH = "/enve/provisioning/result"

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    fun encode(state: WearState): ByteArray = json.encodeToString(WearState.serializer(), state).encodeToByteArray()

    fun decode(bytes: ByteArray): WearState = json.decodeFromString(WearState.serializer(), bytes.decodeToString())

    fun encodeProvisioningRequest(request: WearProvisioningRequest): ByteArray =
        json.encodeToString(WearProvisioningRequest.serializer(), request).encodeToByteArray()

    fun decodeProvisioningRequest(bytes: ByteArray): WearProvisioningRequest =
        json.decodeFromString(WearProvisioningRequest.serializer(), bytes.decodeToString())

    fun encodeProvisionedConnection(connection: WearProvisionedConnection): ByteArray =
        json.encodeToString(WearProvisionedConnection.serializer(), connection).encodeToByteArray()

    fun decodeProvisionedConnection(bytes: ByteArray): WearProvisionedConnection =
        json.decodeFromString(WearProvisionedConnection.serializer(), bytes.decodeToString())

    fun encodeProvisioningEnvelope(envelope: WearProvisioningEnvelope): ByteArray =
        json.encodeToString(WearProvisioningEnvelope.serializer(), envelope).encodeToByteArray()

    fun decodeProvisioningEnvelope(bytes: ByteArray): WearProvisioningEnvelope =
        json.decodeFromString(WearProvisioningEnvelope.serializer(), bytes.decodeToString())

    fun encodeProvisioningResult(result: WearProvisioningResult): ByteArray =
        json.encodeToString(WearProvisioningResult.serializer(), result).encodeToByteArray()

    fun decodeProvisioningResult(bytes: ByteArray): WearProvisioningResult =
        json.decodeFromString(WearProvisioningResult.serializer(), bytes.decodeToString())
}

object WearProvisioningCrypto {
    private val random = SecureRandom()

    fun encrypt(publicKeyBytes: ByteArray, requestId: String, plaintext: ByteArray): WearProvisioningEnvelope {
        val publicKey = KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(publicKeyBytes))
        val secret = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val nonce = ByteArray(12).also(random::nextBytes)
        val content = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, secret, GCMParameterSpec(128, nonce))
            updateAAD(aad(requestId))
        }.doFinal(plaintext)
        val wrapped = rsaCipher(Cipher.ENCRYPT_MODE, publicKey).doFinal(secret.encoded)
        return WearProvisioningEnvelope(requestId, wrapped, nonce, content)
    }

    fun decrypt(privateKey: PrivateKey, envelope: WearProvisioningEnvelope): ByteArray {
        val secret = rsaCipher(Cipher.DECRYPT_MODE, privateKey).doFinal(envelope.encryptedKey)
        return Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, javax.crypto.spec.SecretKeySpec(secret, "AES"), GCMParameterSpec(128, envelope.nonce))
            updateAAD(aad(envelope.requestId))
        }.doFinal(envelope.ciphertext)
    }

    private fun rsaCipher(mode: Int, key: java.security.Key): Cipher =
        Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding").apply {
            init(
                mode,
                key,
                OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT),
            )
        }

    private fun aad(requestId: String): ByteArray = MessageDigest.getInstance("SHA-256")
        .digest("enve-wear-provisioning-v1:$requestId".encodeToByteArray())
}
