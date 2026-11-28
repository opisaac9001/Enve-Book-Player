package com.enve.app.data.backup

import com.enve.engine.backup.SettingsTransferOffer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.security.SecureRandom
import java.text.Normalizer
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

internal object SettingsTransferWire {
    const val maxBytes = 16 * 1024 * 1024
    private const val format = "enve-settings-backup"
    private const val version = 1
    private val random = SecureRandom()
    private val json = Json { ignoreUnknownKeys = true }

    @Serializable
    private data class Envelope(val format: String, val version: Int, val salt: String, val payload: String)

    class Pairing(val host: String, val port: Int, val key: ByteArray) {
        val passphrase: String get() = Base64.getUrlEncoder().withoutPadding().encodeToString(key)
        val code: String get() = "enve-settings:1:$host:$port:$passphrase"
    }

    private fun randomBytes(count: Int) = ByteArray(count).also(random::nextBytes)

    fun seal(payload: ByteArray, passphrase: String): ByteArray {
        require(payload.size <= maxBytes)
        val salt = randomBytes(16)
        val nonce = randomBytes(12)
        val cipher = cipher(Cipher.ENCRYPT_MODE, passphrase, salt, nonce)
        return json.encodeToString(
            Envelope(format, version, Base64.getEncoder().encodeToString(salt),
                Base64.getEncoder().encodeToString(nonce + cipher.doFinal(payload))),
        ).encodeToByteArray().also { require(it.size <= maxBytes) }
    }

    fun open(bytes: ByteArray, passphrase: String): ByteArray {
        require(bytes.size <= maxBytes)
        val envelope = json.decodeFromString<Envelope>(bytes.decodeToString(throwOnInvalidSequence = true))
        require(envelope.format == format && envelope.version == version) { "Unsupported backup version" }
        val salt = Base64.getDecoder().decode(envelope.salt)
        val combined = Base64.getDecoder().decode(envelope.payload)
        require(salt.size == 16 && combined.size >= 28)
        return cipher(Cipher.DECRYPT_MODE, passphrase, salt, combined.copyOfRange(0, 12))
            .doFinal(combined, 12, combined.size - 12)
    }

    private fun cipher(mode: Int, passphrase: String, salt: ByteArray, nonce: ByteArray): Cipher {
        val normalized = Normalizer.normalize(passphrase, Normalizer.Form.NFC)
        require(normalized.isNotEmpty() && normalized.encodeToByteArray().size <= 1024)
        val spec = PBEKeySpec(normalized.toCharArray(), salt, 600_000, 256)
        val key = try { SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded }
        finally { spec.clearPassword() }
        return Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            updateAAD("enve-settings-backup:1".encodeToByteArray() + salt)
        }
    }

    fun parse(code: String): Pairing {
        require(code.length <= 128)
        val parts = code.split(':', limit = 6)
        require(parts.size == 5 && parts[0] == "enve-settings" && parts[1] == "1")
        require(isLocalAddress(parts[2]))
        val port = parts[3].toIntOrNull()
        require(port != null && port in 1..65535)
        require(parts[4].length == 43)
        val key = Base64.getUrlDecoder().decode(parts[4])
        require(key.size == 32)
        return Pairing(parts[2], port, key)
    }

    fun isLocalAddress(host: String): Boolean {
        val octets = host.split('.')
        if (octets.size != 4) return false
        val bytes = octets.map { part ->
            val n = part.toIntOrNull()
            if (n == null || n !in 0..255 || n.toString() != part) return false
            n
        }
        return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] in 16..31) ||
            (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
    }

    fun offer(host: String, payload: ByteArray): SettingsTransferOffer {
        require(isLocalAddress(host))
        val key = randomBytes(32)
        val server = ServerSocket()
        try {
            server.bind(InetSocketAddress(InetAddress.getByName(host), 0))
            val pairing = Pairing(host, server.localPort, key)
            val sealed = seal(payload, pairing.passphrase)
            return LocalOffer(server, pairing, sealed)
        } catch (error: Exception) {
            server.close()
            throw error
        }
    }

    suspend fun receive(code: String): ByteArray = runInterruptible(Dispatchers.IO) {
        val pairing = parse(code)
        Socket().use { socket ->
            socket.connect(InetSocketAddress(pairing.host, pairing.port), 5000)
            val deadline = System.nanoTime() + 12_000_000_000
            val input = DataInputStream(socket.getInputStream())
            val output = DataOutputStream(socket.getOutputStream())
            val challenge = readExactly(input, socket, 16, deadline)
            output.write(proof(pairing.key, challenge))
            output.flush()
            val count = java.nio.ByteBuffer.wrap(readExactly(input, socket, 4, deadline)).int
            require(count in 1..maxBytes)
            open(readExactly(input, socket, count, deadline), pairing.passphrase)
        }
    }

    fun readExactly(input: DataInputStream, socket: Socket, count: Int, deadline: Long): ByteArray {
        val data = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val remaining = (deadline - System.nanoTime()) / 1_000_000
            if (remaining <= 0) throw SocketTimeoutException("Transfer expired")
            socket.soTimeout = remaining.toInt().coerceAtLeast(1)
            val bytes = input.read(data, offset, count - offset)
            if (bytes < 0) throw IOException("Transfer ended early")
            offset += bytes
        }
        return data
    }

    private fun proof(key: ByteArray, challenge: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256"))
        update("enve.settings.transfer.request.v1".encodeToByteArray())
        doFinal(challenge)
    }

    private class LocalOffer(
        private val server: ServerSocket,
        private val pairing: Pairing,
        private val payload: ByteArray,
    ) : SettingsTransferOffer {
        private val deadline = System.nanoTime() + 90_000_000_000
        @Volatile private var connection: Socket? = null
        override val code: String get() = pairing.code

        override suspend fun awaitTransfer() = coroutineScope {
            val expiry = launch {
                delay(((deadline - System.nanoTime()) / 1_000_000).coerceAtLeast(0))
                close()
            }
            try {
                runInterruptible(Dispatchers.IO) { serve() }
            } finally {
                expiry.cancel()
                close()
            }
        }

        private fun serve() {
            try {
                while (true) {
                    val timeLeft = (deadline - System.nanoTime()) / 1_000_000
                    if (timeLeft <= 0) throw SocketTimeoutException("Transfer expired")
                    server.soTimeout = timeLeft.toInt().coerceAtLeast(1)
                    val socket = server.accept()
                    connection = socket
                    socket.use {
                        socket.soTimeout = timeLeft.toInt().coerceIn(1, 3000)
                        val input = DataInputStream(socket.getInputStream())
                        val output = DataOutputStream(socket.getOutputStream())
                        val challenge = randomBytes(16)
                        val valid = try {
                            output.write(challenge)
                            output.flush()
                            val supplied = readExactly(input, socket, 32, minOf(deadline, System.nanoTime() + 3_000_000_000))
                            MessageDigest.isEqual(supplied, proof(pairing.key, challenge))
                        } catch (_: IOException) { false }
                        if (valid && System.nanoTime() < deadline && !server.isClosed) {
                            server.close()
                            output.writeInt(payload.size)
                            output.write(payload)
                            output.flush()
                            return
                        }
                    }
                    connection = null
                }
            } finally { close() }
        }

        override fun close() {
            server.close()
            connection?.close()
        }
    }
}
