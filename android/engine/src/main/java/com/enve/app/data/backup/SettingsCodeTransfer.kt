package com.enve.app.data.backup

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import com.enve.engine.backup.SettingsCodeOffer
import com.enve.pairing.SettingsPairing
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

internal object SettingsCodeTransfer {
    private const val serviceType = "_enve-settings._tcp."
    private const val expiryMillis = 90_000L
    private const val handshakeNanos = 7_000_000_000L

    suspend fun offer(context: Context, host: String, backup: suspend (String) -> ByteArray): SettingsCodeOffer {
        val server = ServerSocket()
        try {
            server.bind(InetSocketAddress(InetAddress.getByName(host), 0))
            val offer = LocalOffer(context.getSystemService(NsdManager::class.java), server, backup)
            try {
                offer.advertise()
                return offer
            } catch (error: Exception) {
                offer.close()
                throw error
            }
        } catch (error: Exception) {
            server.close()
            throw error
        }
    }

    suspend fun receive(context: Context, code: String): ByteArray = withContext(Dispatchers.IO) {
        require(code.length == 6 && code.all { it in '0'..'9' })
        val nsd = context.getSystemService(NsdManager::class.java)
        for (service in discover(nsd).take(8)) {
            val endpoint = try {
                withTimeoutOrNull(3_000) { resolve(nsd, service) }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: IOException) { null } ?: continue
            receiveAt(endpoint, code)?.let { return@withContext it }
        }
        throw IOException("Could not pair with another Enve device")
    }

    private suspend fun receiveAt(endpoint: InetSocketAddress, code: String): ByteArray? = coroutineScope {
        Socket().use { socket ->
            val onCancel = launch(start = CoroutineStart.UNDISPATCHED) {
                try { awaitCancellation() } finally { socket.close() }
            }
            try {
                runInterruptible {
                    val input: DataInputStream
                    val key = try {
                        socket.connect(endpoint, 3_000)
                        input = DataInputStream(socket.getInputStream())
                        val output = DataOutputStream(socket.getOutputStream())
                        pair(code, sender = false, input, output, socket, System.nanoTime() + handshakeNanos)
                    } catch (_: IOException) { return@runInterruptible null }
                    val sealed = readFrame(input, socket, SettingsTransferWire.maxBytes, System.nanoTime() + expiryMillis * 1_000_000)
                    SettingsTransferWire.open(sealed, passphrase(key))
                }
            } finally {
                onCancel.cancel()
            }
        }
    }

    private suspend fun discover(nsd: NsdManager): List<NsdServiceInfo> {
        val results = linkedMapOf<String, NsdServiceInfo>()
        withTimeoutOrNull(4_000) {
            callbackFlow<Pair<Boolean, NsdServiceInfo>> {
                val listener = object : NsdManager.DiscoveryListener {
                    override fun onDiscoveryStarted(type: String) = Unit
                    override fun onDiscoveryStopped(type: String) = Unit
                    override fun onStartDiscoveryFailed(type: String, code: Int) { close(IOException("Could not find nearby devices")) }
                    override fun onStopDiscoveryFailed(type: String, code: Int) = Unit
                    override fun onServiceFound(info: NsdServiceInfo) { trySend(true to info) }
                    override fun onServiceLost(info: NsdServiceInfo) { trySend(false to info) }
                }
                nsd.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
                awaitClose { runCatching { nsd.stopServiceDiscovery(listener) } }
            }.collect { (found, service) ->
                if (found) results[service.serviceName] = service else results.remove(service.serviceName)
            }
        }
        return results.values.toList()
    }

    @Suppress("DEPRECATION")
    private suspend fun resolve(nsd: NsdManager, info: NsdServiceInfo): InetSocketAddress {
        val result = CompletableDeferred<InetSocketAddress>()
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, code: Int) {
                result.completeExceptionally(IOException("Could not connect to the nearby device"))
            }

            override fun onServiceResolved(info: NsdServiceInfo) {
                val addresses = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
                val host = addresses.firstOrNull { it.hostAddress?.let(SettingsTransferWire::isLocalAddress) == true }
                if (host != null && info.port in 1..65535) {
                    result.complete(InetSocketAddress(host, info.port))
                } else {
                    result.completeExceptionally(IOException("The device is outside your local network"))
                }
            }
        })
        return result.await()
    }

    private class LocalOffer(
        private val nsd: NsdManager,
        private val server: ServerSocket,
        private val backup: suspend (String) -> ByteArray,
    ) : SettingsCodeOffer {
        override val code = SecureRandom().nextInt(1_000_000).toString().padStart(6, '0')
        private val deadline = System.nanoTime() + expiryMillis * 1_000_000
        private val ready = CompletableDeferred<Unit>()
        private val approved = CompletableDeferred<Boolean>()
        private val approval = MutableStateFlow(false)
        override val awaitingApproval = approval.asStateFlow()
        @Volatile private var peer: Socket? = null

        private val registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                if (server.isClosed) unregister() else ready.complete(Unit)
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {
                ready.completeExceptionally(IOException("Could not advertise transfer"))
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) = Unit
        }

        suspend fun advertise() {
            val info = NsdServiceInfo().apply {
                serviceName = "Enve " + UUID.randomUUID()
                serviceType = SettingsCodeTransfer.serviceType
                port = server.localPort
            }
            nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration)
            withTimeoutOrNull(8_000) { ready.await() } ?: throw IOException("Could not advertise transfer")
        }

        override suspend fun awaitTransfer() = coroutineScope {
            val expiry = launch {
                delay(remaining().toLong())
                close()
            }
            try {
                repeat(5) {
                    val socket = runInterruptible(Dispatchers.IO) {
                        server.soTimeout = remaining().coerceAtLeast(1)
                        server.accept().also { peer = it }
                    }
                    socket.use {
                        val input = DataInputStream(socket.getInputStream())
                        val output = DataOutputStream(socket.getOutputStream())
                        val key = try {
                            runInterruptible(Dispatchers.IO) {
                                pair(code, sender = true, input, output, socket,
                                    minOf(deadline, System.nanoTime() + handshakeNanos))
                            }
                        } catch (_: IOException) { return@use }
                        approval.value = true
                        if (!approved.await()) throw IOException("Transfer expired")
                        val sealed = backup(passphrase(key))
                        runInterruptible(Dispatchers.IO) {
                            if (remaining() == 0 || server.isClosed) throw IOException("Transfer expired")
                            writeFrame(output, sealed)
                        }
                        return@coroutineScope
                    }
                    peer = null
                }
                throw IOException("Too many attempts. Start a new transfer.")
            } finally {
                expiry.cancel()
                close()
            }
        }

        override fun approve() {
            if (approval.value && !server.isClosed) approved.complete(true)
        }

        override fun close() {
            server.close()
            peer?.close()
            approved.complete(false)
            ready.cancel()
            unregister()
        }

        private fun unregister() { runCatching { nsd.unregisterService(registration) } }

        private fun remaining() = ((deadline - System.nanoTime()) / 1_000_000).coerceAtLeast(0).toInt()
    }

    internal fun pair(code: String, sender: Boolean, input: DataInputStream, output: DataOutputStream, socket: Socket, deadline: Long): ByteArray {
        val secret = SettingsPairing(code, sender).use { pairing ->
            for (round in 1..2) {
                writeFrame(output, pairing.message(round))
                pairing.accept(round, readFrame(input, socket, 512, deadline))
            }
            pairing.secret()
        }
        try {
            val local = if (sender) "sender" else "receiver"
            val remote = if (sender) "receiver" else "sender"
            if (!sender) {
                output.write(mac(secret, local))
                output.flush()
            }
            val proof = SettingsTransferWire.readExactly(input, socket, 32, deadline)
            if (!MessageDigest.isEqual(proof, mac(secret, remote))) throw IOException("Pairing code did not match")
            if (sender) {
                output.write(mac(secret, local))
                output.flush()
            }
            return mac(secret, "backup")
        } finally {
            secret.fill(0)
        }
    }

    private fun mac(key: ByteArray, role: String): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256"))
        doFinal("enve.settings.code.v1.$role".encodeToByteArray())
    }

    private fun passphrase(key: ByteArray) = Base64.getUrlEncoder().withoutPadding().encodeToString(key)

    private fun readFrame(input: DataInputStream, socket: Socket, maximum: Int, deadline: Long): ByteArray {
        val size = ByteBuffer.wrap(SettingsTransferWire.readExactly(input, socket, 4, deadline)).int
        if (size !in 1..maximum) throw IOException("Invalid transfer frame")
        return SettingsTransferWire.readExactly(input, socket, size, deadline)
    }

    private fun writeFrame(output: DataOutputStream, data: ByteArray) {
        output.writeInt(data.size)
        output.write(data)
        output.flush()
    }
}
