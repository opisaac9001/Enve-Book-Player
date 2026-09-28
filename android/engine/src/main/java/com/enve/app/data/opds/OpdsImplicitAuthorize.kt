package com.enve.app.data.opds

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.URI
import java.security.SecureRandom

const val OPDS_IMPLICIT_REDIRECT_URI = "enve://opds-auth"

fun newOpdsImplicitState(): String {
    val bytes = ByteArray(STATE_BYTES)
    stateRandom.nextBytes(bytes)
    return bytes.joinToString("") { HEX[(it.toInt() shr 4) and 0x0F].toString() + HEX[it.toInt() and 0x0F] }
}

fun buildOpdsImplicitAuthorizeUrl(authorizeUrl: String, redirectUri: String, state: String): String? {
    if (state.isBlank()) return null
    val parsed = authorizeUrl.toHttpUrlOrNull() ?: return null
    return parsed.newBuilder()
        .setQueryParameter("response_type", "token")
        .setQueryParameter("redirect_uri", redirectUri)
        .setQueryParameter("state", state)
        .build()
        .toString()
}

fun isOpdsImplicitRedirect(url: String, redirectUri: String): Boolean {
    val expected = redirectTarget(redirectUri) ?: return false
    return expected == redirectTarget(url)
}

private data class RedirectTarget(val scheme: String, val authority: String, val path: String)

private fun redirectTarget(value: String): RedirectTarget? {
    val uri = runCatching { URI(value) }.getOrNull() ?: return null
    val scheme = uri.scheme?.lowercase() ?: return null
    val authority = (uri.host ?: uri.authority)?.lowercase() ?: return null
    return RedirectTarget(scheme, authority, uri.path.orEmpty().trimEnd('/'))
}

private const val STATE_BYTES = 32
private const val HEX = "0123456789abcdef"
private val stateRandom = SecureRandom()
