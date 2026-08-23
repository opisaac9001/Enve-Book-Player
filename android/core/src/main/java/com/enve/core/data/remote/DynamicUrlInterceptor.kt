package com.enve.core.data.remote

import com.enve.core.data.local.PreferencesManager
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class DynamicUrlInterceptor @Inject constructor(
    private val preferencesManager: PreferencesManager,
    private val connectionRegistry: com.enve.core.data.local.ConnectionRegistry,
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val original = chain.request()
        val originalUrl = original.url
        val isPlaceholder = DynamicUrlRewriter.isPlaceholder(originalUrl)

        val connectionId = ConnectionScope.getConnectionId()
        val matchingConnection = if (connectionId != null) {
            connectionRegistry.getConnectionsSync().find { it.id == connectionId }
        } else null

        var serverUrl = matchingConnection?.serverUrl ?: preferencesManager.getServerUrlSync()

        if (serverUrl.isNullOrBlank()) {
            if (isPlaceholder) throw IOException("No server URL configured for request ${originalUrl.encodedPath}")
            return chain.proceed(original)
        }

        val newBaseUrl = DynamicUrlRewriter.normalizedBaseUrl(serverUrl) ?: run {
            if (isPlaceholder) throw IOException("Invalid server URL configured for request ${originalUrl.encodedPath}")
            return chain.proceed(original)
        }
        if (!isPlaceholder) {
            return chain.proceed(original)
        }

        val newRequest = original.newBuilder()
            .url(DynamicUrlRewriter.rewritePlaceholder(originalUrl, newBaseUrl))
            .header("Accept", "application/json")
            .build()

        return chain.proceed(newRequest)
    }
}

internal object DynamicUrlRewriter {
    fun isPlaceholder(url: HttpUrl): Boolean =
        (url.host == "localhost" || url.host == "127.0.0.1") && url.port == 80

    fun normalizedBaseUrl(rawServerUrl: String): HttpUrl? {
        val cleaned = cleanServerUrl(rawServerUrl)
        val normalized = if (cleaned.contains("://")) cleaned else "https://$cleaned"
        return normalized.toHttpUrlOrNull()
    }

    fun rewritePlaceholder(originalUrl: HttpUrl, newBaseUrl: HttpUrl): HttpUrl {
        val newUrlBuilder = newBaseUrl.newBuilder().encodedPath("/")
        newBaseUrl.pathSegments.filter { it.isNotEmpty() }.forEach {
            newUrlBuilder.addEncodedPathSegment(it)
        }
        originalUrl.pathSegments.forEach {
            newUrlBuilder.addEncodedPathSegment(it)
        }
        originalUrl.query?.let { newUrlBuilder.encodedQuery(it) }
        return newUrlBuilder.build()
    }

    private fun cleanServerUrl(rawServerUrl: String): String {
        val serverUrl = rawServerUrl.filter { it >= ' ' }.trim()
        val protocolMatches = Regex("https?://", RegexOption.IGNORE_CASE).findAll(serverUrl).toList()
        if (protocolMatches.size < 2) return serverUrl

        val secondStart = protocolMatches[1].range.first
        val beforeSecond = serverUrl.substring(0, secondStart).trimEnd('/')
        val beforeHost = beforeSecond.substringAfter("://", missingDelimiterValue = "")
        return if (beforeHost.isBlank() || (!beforeHost.contains('.') && !beforeHost.contains(':'))) {
            serverUrl.substring(secondStart).trim()
        } else {
            beforeSecond.trim()
        }
    }
}
