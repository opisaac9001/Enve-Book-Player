package com.enve.app.playback

import com.enve.core.data.remote.ConnectionScope
import okhttp3.Interceptor
import okhttp3.Response
import java.net.URLDecoder
import java.net.URLEncoder

private const val CONNECTION_STREAM_FRAGMENT_PREFIX = "enve-connection="
internal const val STREAM_CONNECTION_HEADER = "X-Enve-Stream-Connection"

internal fun connectionStreamUrl(url: String, connectionId: String?): String {
    if (connectionId.isNullOrBlank() || '#' in url) return url
    val scheme = url.substringBefore("://", missingDelimiterValue = "").lowercase()
    if (scheme != "http" && scheme != "https") return url
    return "$url#$CONNECTION_STREAM_FRAGMENT_PREFIX${URLEncoder.encode(connectionId, Charsets.UTF_8.name())}"
}

internal fun streamConnectionId(fragment: String?): String? =
    fragment
        ?.takeIf { it.startsWith(CONNECTION_STREAM_FRAGMENT_PREFIX) }
        ?.removePrefix(CONNECTION_STREAM_FRAGMENT_PREFIX)
        ?.let { URLDecoder.decode(it, Charsets.UTF_8.name()) }
        ?.takeIf { it.isNotBlank() }

internal object StreamConnectionInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val connectionId = request.header(STREAM_CONNECTION_HEADER) ?: return chain.proceed(request)
        val stripped = request.newBuilder().removeHeader(STREAM_CONNECTION_HEADER).build()
        return ConnectionScope.withConnectionId(connectionId) { chain.proceed(stripped) }
    }
}
