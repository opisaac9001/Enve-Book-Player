package com.enve.engine.podcasts

import java.net.URI
import java.net.URISyntaxException
import java.net.URLDecoder
import java.util.Locale
import java.util.UUID

enum class PodcastFeedPrivacyConcern(val explanation: String) {
    CREDENTIALS("Contains a username or password"),
    ACCESS_KEY("Contains an access key"),
    PRIVATE_FEED("Looks like a private or supporter feed"),
    OPAQUE_TOKEN("Contains what looks like a personal token"),
}

object PodcastFeedUrl {
    private const val MAX_LENGTH = 4096
    private val schemeAliases = listOf("feed:", "itpc:", "pcast:", "podcast:")
    private val sensitiveQueryNames = setOf(
        "key", "sig", "pass", "pwd", "sid", "hash", "code", "jwt", "login", "user", "username", "email",
    )
    private val sensitiveQueryFragments = listOf(
        "token", "auth", "secret", "signature", "password", "apikey", "api_key", "accesskey", "access_key", "session",
    )
    private val privatePathSegments = setOf(
        "private", "premium", "patron", "patrons", "member", "members", "subscriber", "subscribers", "supporter",
        "supporters", "paid",
    )
    private val privateHostSuffixes = listOf(
        "patreon.com", "supercast.com", "supercast.tech", "supportingcast.fm", "memberful.com", "memberfulcontent.com",
        "glow.fm", "subscribestar.com", "subscribestar.adult",
    )
    private val tokenCharacters = Regex("[A-Za-z0-9_-]+")

    fun canonical(raw: String): String? {
        var text = raw.trim()
        if (text.isEmpty() || text.length > MAX_LENGTH) return null
        val lowered = text.lowercase(Locale.ROOT)
        schemeAliases.firstOrNull { lowered.startsWith(it) }?.let { alias ->
            val rest = text.substring(alias.length)
            text = if (rest.startsWith("//")) "http:$rest" else rest
        }
        val uri = try {
            URI(text)
        } catch (_: URISyntaxException) {
            return null
        }
        val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: return null
        if (scheme != "http" && scheme != "https") return null
        val host = uri.host?.takeIf { it.isNotEmpty() }?.lowercase(Locale.ROOT) ?: return null
        val port = uri.port.takeUnless { it == -1 || (scheme == "http" && it == 80) || (scheme == "https" && it == 443) }
        return buildString {
            append(scheme).append("://")
            uri.rawUserInfo?.let { append(it).append('@') }
            append(host)
            port?.let { append(':').append(it) }
            append(uri.rawPath?.takeIf { it.isNotEmpty() } ?: "/")
            uri.rawQuery?.let { append('?').append(it) }
        }
    }

    fun key(raw: String): String {
        val canonical = canonical(raw) ?: return raw.trim().lowercase(Locale.ROOT)
        return canonical.removePrefix("https://").removePrefix("http://")
    }

    fun showId(feedUrl: String): String = UUID.nameUUIDFromBytes(feedUrl.toByteArray()).toString()

    fun privacyConcern(raw: String): PodcastFeedPrivacyConcern? {
        val uri = try {
            URI(canonical(raw) ?: raw.trim())
        } catch (_: URISyntaxException) {
            return null
        }
        if (uri.rawUserInfo != null) return PodcastFeedPrivacyConcern.CREDENTIALS

        uri.rawQuery?.split('&')?.filter(String::isNotEmpty)?.forEach { item ->
            val name = URLDecoder.decode(item.substringBefore('='), "UTF-8").lowercase(Locale.ROOT)
            if (name in sensitiveQueryNames || sensitiveQueryFragments.any(name::contains)) {
                return PodcastFeedPrivacyConcern.ACCESS_KEY
            }
            if ('=' in item && isOpaqueToken(URLDecoder.decode(item.substringAfter('='), "UTF-8"))) return PodcastFeedPrivacyConcern.ACCESS_KEY
        }

        val host = uri.host?.lowercase(Locale.ROOT).orEmpty()
        if (privateHostSuffixes.any { host == it || host.endsWith(".$it") }) return PodcastFeedPrivacyConcern.PRIVATE_FEED

        val segments = uri.path.orEmpty().split('/').filter(String::isNotEmpty)
        if (segments.any { it.lowercase(Locale.ROOT) in privatePathSegments }) return PodcastFeedPrivacyConcern.PRIVATE_FEED
        if (segments.any { isOpaqueToken(it.substringBeforeLast('.')) }) return PodcastFeedPrivacyConcern.OPAQUE_TOKEN
        return null
    }

    private fun isOpaqueToken(value: String): Boolean {
        if (value.length < 32 || isUuid(value) || !tokenCharacters.matches(value)) return false
        return value.any(Char::isLetter) && value.any(Char::isDigit)
    }

    private fun isUuid(value: String): Boolean = try {
        UUID.fromString(value).toString().equals(value, ignoreCase = true)
    } catch (_: IllegalArgumentException) {
        false
    }
}
