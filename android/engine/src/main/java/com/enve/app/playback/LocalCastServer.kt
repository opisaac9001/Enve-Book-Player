package com.enve.app.playback

import android.content.ContentResolver
import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkAddress
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.provider.OpenableColumns
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import fi.iki.elonen.NanoHTTPD
import java.io.ByteArrayInputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.net.Inet4Address
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.min

internal sealed interface HttpRange {
    data object Full : HttpRange
    data object Unsatisfiable : HttpRange
    data class Partial(val start: Long, val endInclusive: Long) : HttpRange
}

internal fun resolveHttpRange(header: String?, length: Long): HttpRange {
    if (header.isNullOrBlank()) return HttpRange.Full
    if (!header.startsWith("bytes=", ignoreCase = true)) return HttpRange.Full
    if (length <= 0L) return HttpRange.Unsatisfiable
    val value = header.substringAfter('=').trim()
    if (',' in value) return HttpRange.Full
    val parts = value.split('-', limit = 2)
    if (parts.size != 2) return HttpRange.Unsatisfiable

    val startText = parts[0].trim()
    val endText = parts[1].trim()
    if (startText.isEmpty()) {
        val suffixLength = endText.toLongOrNull()?.takeIf { it > 0L }
            ?: return HttpRange.Unsatisfiable
        return HttpRange.Partial(
            start = (length - suffixLength).coerceAtLeast(0L),
            endInclusive = length - 1L,
        )
    }

    val start = startText.toLongOrNull()?.takeIf { it >= 0L }
        ?: return HttpRange.Unsatisfiable
    if (start >= length) return HttpRange.Unsatisfiable
    val requestedEnd = if (endText.isEmpty()) {
        length - 1L
    } else {
        endText.toLongOrNull()?.takeIf { it >= start } ?: return HttpRange.Unsatisfiable
    }
    return HttpRange.Partial(start, min(requestedEnd, length - 1L))
}

@Singleton
class LocalCastServer @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private data class RegisteredSource(
        val uri: Uri,
        val displayName: String,
        val mimeType: String,
        val length: Long,
    )

    private var server: Server? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    @Volatile private var sessionSecret: String = ""
    private val registry = ConcurrentHashMap<String, RegisteredSource>()
    private val sourceIds = ConcurrentHashMap<Uri, String>()

    @Synchronized
    fun start(): Boolean {
        if (server != null) return true
        val ip = pickLanIpv4() ?: return false
        return try {
            val s = Server(ip, 0).also { it.start(NanoHTTPD.SOCKET_READ_TIMEOUT, true) }
            server = s
            sessionSecret = UUID.randomUUID().toString().replace("-", "")
            acquireLocks()
            Log.i(TAG, "started on http://$ip:${s.listeningPort}/")
            true
        } catch (e: Exception) {
            Log.w(TAG, "start failed", e)
            null.also { server = null }
            false
        }
    }

    @Synchronized
    fun stop() {
        server?.runCatching { stop() }
        server = null
        sessionSecret = ""
        registry.clear()
        sourceIds.clear()
        releaseLocks()
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        if (wifiLock != null) return
        val wifi = context.getSystemService(WifiManager::class.java)
        wifiLock = wifi?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "enve:cast")
            ?.apply { setReferenceCounted(false); acquire() }
        val power = context.getSystemService(PowerManager::class.java)
        wakeLock = power?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "enve:cast")
            ?.apply { setReferenceCounted(false); acquire() }
    }

    private fun releaseLocks() {
        wifiLock?.runCatching { if (isHeld) release() }
        wifiLock = null
        wakeLock?.runCatching { if (isHeld) release() }
        wakeLock = null
    }

    @Synchronized
    fun urlFor(uri: Uri): String? {
        val s = server ?: return null
        val source = registeredSource(uri) ?: return null
        val id = sourceIds.getOrPut(uri) {
            UUID.randomUUID().toString().replace("-", "")
        }
        registry[id] = source
        val name = Uri.encode(source.displayName.ifBlank { "audio" })
        return "http://${s.boundIp}:${s.listeningPort}/cast/$sessionSecret/$id/$name"
    }

    @Synchronized
    fun sourceUriFor(url: Uri): Uri? {
        val s = server ?: return null
        if (!url.scheme.equals("http", ignoreCase = true) ||
            url.host != s.boundIp ||
            url.port != s.listeningPort
        ) {
            return null
        }
        val parts = url.pathSegments
        if (parts.size < 4 || parts[0] != "cast" || parts[1] != sessionSecret) return null
        return registry[parts[2]]?.uri
    }

    private fun registeredSource(uri: Uri): RegisteredSource? = when (uri.scheme?.lowercase()) {
        ContentResolver.SCHEME_FILE -> {
            val file = uri.path?.let(::File)?.takeIf { it.exists() && it.isFile } ?: return null
            RegisteredSource(
                uri = uri,
                displayName = file.name,
                mimeType = AudioPlaybackManager.guessMimeType(file.name),
                length = file.length(),
            )
        }
        ContentResolver.SCHEME_CONTENT -> contentSource(uri)
        else -> null
    }

    private fun contentSource(uri: Uri): RegisteredSource? {
        val resolver = context.contentResolver
        var displayName: String? = null
        var length: Long? = null
        runCatching {
            resolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        .takeIf { it >= 0 && !cursor.isNull(it) }
                        ?.let { displayName = cursor.getString(it) }
                    cursor.getColumnIndex(OpenableColumns.SIZE)
                        .takeIf { it >= 0 && !cursor.isNull(it) }
                        ?.let { length = cursor.getLong(it).takeIf { size -> size >= 0L } }
                }
            }
        }.onFailure { Log.w(TAG, "Unable to inspect local media URI", it) }

        if (length == null) {
            length = runCatching {
                resolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                    descriptor.length.takeIf { it >= 0L }
                        ?: descriptor.parcelFileDescriptor.statSize
                            .minus(descriptor.startOffset)
                            .takeIf { it >= 0L }
                }
            }.getOrNull()
        }
        val resolvedLength = length ?: return null
        val resolvedName = displayName ?: uri.lastPathSegment.orEmpty().ifBlank { "audio" }
        return RegisteredSource(
            uri = uri,
            displayName = resolvedName,
            mimeType = runCatching { resolver.getType(uri) }.getOrNull()
                ?: AudioPlaybackManager.guessMimeType(resolvedName),
            length = resolvedLength,
        )
    }

    @Suppress("DEPRECATION")
    private fun pickLanIpv4(): String? {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
        val networks = buildList {
            cm.activeNetwork?.let(::add)
            cm.allNetworks.forEach { network ->
                if (network !in this) add(network)
            }
        }
        for (network: Network in networks) {
            val capabilities = cm.getNetworkCapabilities(network) ?: continue
            val isLanTransport =
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
            if (!isLanTransport || capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue

            val candidates: List<LinkAddress> = cm.getLinkProperties(network)?.linkAddresses ?: continue
            for (link in candidates) {
                val address = link.address
                if (address is Inet4Address && !address.isLoopbackAddress && !address.isLinkLocalAddress) {
                    return address.hostAddress
                }
            }
        }
        Log.w(TAG, "No Wi-Fi or Ethernet IPv4 address is available for Cast")
        return null
    }

    private inner class Server(val boundIp: String, port: Int) : NanoHTTPD(boundIp, port) {
        override fun serve(session: IHTTPSession): Response =
            serveCastRequest(session).apply {
                session.headers["origin"]?.takeIf { it.isNotBlank() }?.let { origin ->
                    addHeader("Access-Control-Allow-Origin", origin)
                    addHeader("Vary", "Origin")
                }
                addHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
                addHeader("Access-Control-Allow-Headers", "Range, Content-Type, Accept-Encoding")
                addHeader("Access-Control-Expose-Headers", "Accept-Ranges, Content-Length, Content-Range, Content-Type")
            }

        private fun serveCastRequest(session: IHTTPSession): Response {
            if (session.method == Method.OPTIONS) {
                return newFixedLengthResponse(Response.Status.NO_CONTENT, "text/plain", "")
            }
            if (session.method != Method.GET && session.method != Method.HEAD) {
                return newFixedLengthResponse(
                    Response.Status.METHOD_NOT_ALLOWED,
                    "text/plain",
                    "Method Not Allowed",
                ).apply { addHeader("Allow", "GET, HEAD, OPTIONS") }
            }
            val uri = session.uri.orEmpty()
            val parts = uri.trim('/').split('/', limit = 4)
            if (parts.size < 4 || parts[0] != "cast") return forbidden()
            if (sessionSecret.isEmpty() || parts[1] != sessionSecret) return forbidden()
            val id = parts[2]
            val source = registry[id] ?: return notFound()
            return if (session.method == Method.HEAD) {
                headerOnlyResponse(Response.Status.OK, source.mimeType, source.length)
                    .apply { addHeader("Accept-Ranges", "bytes") }
            } else {
                serveSourceWithRange(session, source)
            }
        }

        private fun forbidden(): Response =
            newFixedLengthResponse(Response.Status.FORBIDDEN, "text/plain", "Forbidden")

        private fun notFound(): Response =
            newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "Not Found")

        private fun serveSourceWithRange(
            session: IHTTPSession,
            source: RegisteredSource,
        ): Response {
            val length = source.length
            return when (val range = resolveHttpRange(session.headers["range"], length)) {
                HttpRange.Full -> sourceResponse(
                    source = source,
                    status = Response.Status.OK,
                    start = 0L,
                    contentLength = length,
                )
                HttpRange.Unsatisfiable -> newFixedLengthResponse(
                    Response.Status.RANGE_NOT_SATISFIABLE,
                    "text/plain",
                    "",
                ).apply {
                    addHeader("Content-Range", "bytes */$length")
                    addHeader("Accept-Ranges", "bytes")
                }
                is HttpRange.Partial -> {
                    val contentLength = range.endInclusive - range.start + 1L
                    sourceResponse(
                        source = source,
                        status = Response.Status.PARTIAL_CONTENT,
                        start = range.start,
                        contentLength = contentLength,
                    ).apply {
                        addHeader("Content-Range", "bytes ${range.start}-${range.endInclusive}/$length")
                    }
                }
            }
        }

        private fun sourceResponse(
            source: RegisteredSource,
            status: Response.Status,
            start: Long,
            contentLength: Long,
        ): Response {
            val stream = openSource(source, start) ?: return notFound()
            return newFixedLengthResponse(status, source.mimeType, stream, contentLength)
                .apply { addHeader("Accept-Ranges", "bytes") }
        }

        private fun headerOnlyResponse(
            status: Response.IStatus,
            mime: String,
            contentLength: Long,
        ): Response =
            newFixedLengthResponse(
                status,
                mime,
                ByteArrayInputStream(ByteArray(0)),
                contentLength,
            )

        private fun openSource(source: RegisteredSource, start: Long): InputStream? =
            runCatching {
                when (source.uri.scheme?.lowercase()) {
                    ContentResolver.SCHEME_FILE -> {
                        FileInputStream(File(requireNotNull(source.uri.path))).apply {
                            channel.position(start)
                        }
                    }
                    ContentResolver.SCHEME_CONTENT -> {
                        val stream = context.contentResolver.openInputStream(source.uri)
                            ?: throw EOFException("Unable to open local media")
                        try {
                            stream.skipFully(start)
                            stream
                        } catch (e: Exception) {
                            stream.close()
                            throw e
                        }
                    }
                    else -> null
                }
            }.onFailure { Log.w(TAG, "Unable to open local media for Cast", it) }
                .getOrNull()

        private fun InputStream.skipFully(byteCount: Long) {
            var remaining = byteCount
            var canSeek = true
            val buffer = ByteArray(16 * 1024)
            while (remaining > 0L) {
                val skipped = if (canSeek) {
                    try {
                        skip(remaining)
                    } catch (_: Exception) {
                        canSeek = false
                        0L
                    }
                } else {
                    0L
                }
                if (skipped > 0L) {
                    remaining -= skipped
                } else {
                    canSeek = false
                    val read = read(buffer, 0, min(buffer.size.toLong(), remaining).toInt())
                    if (read == -1) {
                        throw EOFException("Local media ended before requested range")
                    }
                    remaining -= read
                }
            }
        }
    }

    companion object {
        private const val TAG = "LocalCastServer"
    }
}
