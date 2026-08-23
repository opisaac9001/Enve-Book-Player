package com.enve.core.data.playback

import com.enve.core.data.model.BookSource
import java.net.InetAddress

object CastCompatibility {

    private val queryAuthSources = setOf(
        BookSource.AUDIOBOOKSHELF,
        BookSource.PLEX,
        BookSource.GRIMMORY,
        BookSource.JELLYFIN,
        BookSource.EMBY,
        BookSource.SILO,
        BookSource.PREMIUMIZE,
        BookSource.REALDEBRID,
    )

    fun canCastStream(source: BookSource): Boolean = source in queryAuthSources

    fun receiverCanValidate(url: String): Boolean {
        val lower = url.lowercase()
        if (!lower.startsWith("https://")) return true
        val host = runCatching { java.net.URI(url).host }.getOrNull()?.lowercase() ?: return false
        if (host.endsWith(".plex.direct")) return true
        if (host.endsWith(".ts.net") || host.endsWith(".local") ||
            host.endsWith(".lan") || host.endsWith(".home") || host.endsWith(".internal")
        ) {
            return false
        }
        val literal = runCatching { InetAddress.getByName(host) }.getOrNull()
        if (literal != null && literal.hostAddress == host) return false
        return true
    }
}
