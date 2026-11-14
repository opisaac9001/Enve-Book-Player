package com.enve.core.data.model

import java.net.URI

object PodcastEpisodeShareLink {
    private val dnsHost = Regex("[a-z0-9-]+(\\.[a-z0-9-]+)*\\.[a-z]{2,63}")
    private val localSuffixes = listOf(".local", ".localhost", ".lan", ".internal", ".home", ".corp", ".home.arpa")

    fun url(raw: String?): String? {
        val value = raw?.trim() ?: return null
        val uri = runCatching { URI(value) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()
        val host = uri.host?.lowercase() ?: return null
        if (scheme != "http" && scheme != "https") return null
        if (!dnsHost.matches(host) || localSuffixes.any(host::endsWith)) return null
        if (uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
        if (uri.port != -1 && uri.port != if (scheme == "https") 443 else 80) return null
        return uri.toASCIIString().takeIf { it.length <= 2200 }
    }
}
