package com.enve.core.data.remote.auth

import com.enve.core.data.remote.AuthCredentialScope
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Response

internal class RequestAuthContext(
    val connectionId: String?,
    val serverUrl: String,
    val headerNames: Set<String>,
    val credentialScope: AuthCredentialScope = AuthCredentialScope.SERVER_PATH,
)

internal fun HttpUrl.belongsTo(
    serverUrl: String,
    credentialScope: AuthCredentialScope = AuthCredentialScope.SERVER_PATH,
): Boolean {
    val base = serverUrl.toHttpUrlOrNull() ?: return false
    val prefix = base.encodedPath.trimEnd('/')
    return scheme == base.scheme && host == base.host && port == base.port &&
        (credentialScope == AuthCredentialScope.ORIGIN || encodedPath == prefix || encodedPath.startsWith("$prefix/"))
}

class ConnectionAuthRedirectInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val auth = request.tag(RequestAuthContext::class.java)
        if (auth == null || request.url.belongsTo(auth.serverUrl, auth.credentialScope)) return chain.proceed(request)
        val sanitized = request.newBuilder().apply {
            auth.headerNames.forEach(::removeHeader)
            removeHeader("Authorization")
            removeHeader("Cookie")
        }.build()
        return chain.proceed(sanitized)
    }
}
