package com.enve.app.webimport

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

internal object WebStoryUrls {
    private const val MAX_INPUT_LENGTH = 2048
    private val explicitWebUrl = Regex("^https?://[^\\s/?#\\\\@]+(?:[/?#][^\\s\\\\]*)?$", RegexOption.IGNORE_CASE)
    private val chapterSegment = Regex("(?:^|/)chapter/([A-Za-z0-9_-]+)(?:/|$)")
    private val royalRoadHosts = setOf("royalroad.com", "www.royalroad.com")
    private val royalRoadFiction = Regex("^/fiction/(\\d+)(?:/|$)")

    fun parseInput(raw: String): HttpUrl {
        val trimmed = raw.trim()
        val valid = trimmed.length <= MAX_INPUT_LENGTH &&
            trimmed.none { it.isISOControl() } &&
            explicitWebUrl.matches(trimmed)
        val url = trimmed.takeIf { valid }?.toHttpUrlOrNull()
        if (url == null || url.username.isNotEmpty() || url.password.isNotEmpty()) {
            throw WebStoryImportException(WebStoryImportException.Reason.INVALID_URL)
        }
        return withoutFragment(url)
    }

    fun withoutFragment(url: HttpUrl): HttpUrl = url.newBuilder().fragment(null).build()

    fun sameOrigin(a: HttpUrl, b: HttpUrl): Boolean = a.scheme == b.scheme && a.host == b.host && a.port == b.port

    fun chapterId(url: HttpUrl): String? = chapterSegment.find(url.encodedPath)?.groupValues?.get(1)

    fun royalRoadFictionId(url: HttpUrl): String? =
        if (url.host in royalRoadHosts) royalRoadFiction.find(url.encodedPath)?.groupValues?.get(1) else null

    fun royalRoadFictionUrl(url: HttpUrl, fictionId: String): HttpUrl =
        url.newBuilder().encodedPath("/fiction/$fictionId").query(null).fragment(null).build()
}
