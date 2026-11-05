package com.enve.core.listeningposition

import java.net.URI
import java.util.Base64

object ListeningPositionLink {
    private const val SCHEME = "enve-book"
    private const val HOST = "position"
    private const val WEB_PREFIX = "https://envemedia.com/position/?d="

    fun shareUrl(payload: ListeningPositionPayload): String = WEB_PREFIX + encode(payload.encoded())

    fun message(link: String): String? {
        val uri = runCatching { URI(link) }.getOrNull() ?: return null
        if (!uri.scheme.equals(SCHEME, ignoreCase = true) || !uri.host.equals(HOST, ignoreCase = true)) return null
        val data = uri.rawQuery?.split('&')?.firstOrNull { it.startsWith("d=") }?.removePrefix("d=") ?: return null
        if (data.length > ListeningPositionPayload.MAX_ENCODED_BYTES * 4 / 3 + 4) return null
        return runCatching { String(Base64.getUrlDecoder().decode(data), Charsets.UTF_8) }.getOrNull()
    }

    private fun encode(message: String): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(message.toByteArray(Charsets.UTF_8))
}
