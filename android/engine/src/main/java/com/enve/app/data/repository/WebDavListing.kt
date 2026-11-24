package com.enve.app.data.repository

import com.enve.core.data.util.decodeXmlEntities
import com.enve.core.data.util.resolveAgainst
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody

private val WEBDAV_HREF = Regex("<(?:[a-z]+:)?href>(.*?)</(?:[a-z]+:)?href>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))

private val HTML_ANCHOR_HREF = Regex("<a\\b[^>]*href=[\"']([^\"']+)[\"']", RegexOption.IGNORE_CASE)

private val WEBDAV_PROPFIND_XML = """
    <?xml version="1.0" encoding="utf-8" ?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:resourcetype />
        <d:getcontentlength />
        <d:getlastmodified />
      </d:prop>
    </d:propfind>
""".trimIndent()

internal fun webDavPropfindBody(): RequestBody =
    WEBDAV_PROPFIND_XML.toRequestBody("application/xml; charset=utf-8".toMediaType())

internal fun hrefsFromListing(url: String, listingText: String): List<String> =
    (WEBDAV_HREF.findAll(listingText) + HTML_ANCHOR_HREF.findAll(listingText))
        .mapNotNull { it.groupValues.getOrNull(1)?.trim() }
        .map { decodeXmlEntities(it) }
        .map { resolveAgainst(url, it) }
        .filter { it.isNotBlank() }
        .distinct()
        .toList()
