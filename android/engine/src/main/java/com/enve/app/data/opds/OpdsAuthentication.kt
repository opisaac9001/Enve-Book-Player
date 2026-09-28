package com.enve.app.data.opds

import javax.inject.Inject
import javax.inject.Singleton

class OpdsAuthenticationRequiredException(
    val url: String,
    val document: OpdsAuthenticationDocument?,
) : IllegalStateException("OPDS catalog requires authentication")

sealed interface OpdsLoginResult {
    data object Succeeded : OpdsLoginResult

    data class Failed(val reason: String) : OpdsLoginResult

    data class RedirectRequired(val authorizeUrl: String) : OpdsLoginResult
}

@Singleton
class OpdsAuthenticationService @Inject constructor(
    private val api: OpdsCatalogApi,
    private val authStore: OpdsAuthStore,
    private val oauth: OpdsOAuthClient,
) {

    suspend fun discover(url: String): OpdsAuthenticationDocument? {
        val response = api.fetch(url, OPDS_AUTHENTICATION_ACCEPT)
        val payload = (if (response.isSuccessful) response.body() else response.errorBody())
            ?.use { it.string() }
        return parseOpdsAuthenticationDocument(payload, response.raw().request.url.toString())
    }

    suspend fun signIn(
        connectionId: String,
        method: OpdsAuthenticationMethod,
        username: String,
        password: String,
    ): OpdsLoginResult = when (method.flow) {
        OpdsAuthenticationFlow.BASIC -> {
            authStore.save(
                connectionId,
                OpdsAuthSession(
                    flow = OpdsAuthenticationFlow.BASIC,
                    username = username,
                    password = password,
                ),
            )
            OpdsLoginResult.Succeeded
        }

        OpdsAuthenticationFlow.OAUTH_PASSWORD -> {
            val tokenUrl = method.authenticateUrl
            if (tokenUrl == null) {
                OpdsLoginResult.Failed("no token endpoint")
            } else {
                val token = oauth.password(tokenUrl, username, password)
                if (token == null) {
                    OpdsLoginResult.Failed("the server rejected the credentials")
                } else {
                    authStore.save(
                        connectionId,
                        OpdsAuthSession(
                            flow = OpdsAuthenticationFlow.OAUTH_PASSWORD,
                            username = username,
                            password = password,
                            accessToken = token.accessToken,
                            refreshToken = token.refreshToken,
                            tokenUrl = tokenUrl,
                            refreshUrl = method.refreshUrl ?: tokenUrl,
                            expiresAtMs = token.expiresAtMs,
                        ),
                    )
                    OpdsLoginResult.Succeeded
                }
            }
        }

        OpdsAuthenticationFlow.OAUTH_IMPLICIT ->
            method.authenticateUrl
                ?.let(OpdsLoginResult::RedirectRequired)
                ?: OpdsLoginResult.Failed("no authorization endpoint")

        OpdsAuthenticationFlow.UNSUPPORTED -> OpdsLoginResult.Failed("unsupported authentication type")
    }

    fun completeImplicit(
        connectionId: String,
        method: OpdsAuthenticationMethod,
        callback: OpdsImplicitCallback,
    ): OpdsLoginResult {
        if (callback.accessToken.isBlank()) {
            return OpdsLoginResult.Failed(callback.error ?: "no access token in the redirect")
        }
        authStore.save(
            connectionId,
            OpdsAuthSession(
                flow = OpdsAuthenticationFlow.OAUTH_IMPLICIT,
                accessToken = callback.accessToken,
                refreshToken = callback.refreshToken,
                tokenUrl = method.authenticateUrl,
                refreshUrl = method.refreshUrl,
                expiresAtMs = callback.expiresAtMs,
            ),
        )
        return OpdsLoginResult.Succeeded
    }

    fun signOut(connectionId: String) = authStore.clear(connectionId)
}

data class OpdsImplicitCallback(
    val accessToken: String,
    val refreshToken: String? = null,
    val expiresAtMs: Long? = null,
    val error: String? = null,
)

fun parseOpdsImplicitCallback(
    redirectUrl: String,
    expectedState: String,
    nowMs: Long = System.currentTimeMillis(),
): OpdsImplicitCallback? {
    if (expectedState.isBlank()) return null
    val fragment = redirectUrl.substringAfter('#', "").takeIf { it.isNotBlank() } ?: return null
    val values = fragment.split('&').mapNotNull { pair ->
        val name = pair.substringBefore('=', "").takeIf { it.isNotBlank() } ?: return@mapNotNull null
        name to decodeFormValue(pair.substringAfter('=', ""))
    }.toMap()

    if (values["state"] != expectedState) return null
    values["error"]?.let {
        return OpdsImplicitCallback(accessToken = "", error = it)
    }
    val accessToken = values["access_token"]?.takeIf { it.isNotBlank() } ?: return null
    val tokenType = values["token_type"]
    if (tokenType != null && !tokenType.equals("bearer", ignoreCase = true)) return null
    return OpdsImplicitCallback(
        accessToken = accessToken,
        refreshToken = values["refresh_token"]?.takeIf { it.isNotBlank() },
        expiresAtMs = values["expires_in"]?.trim()?.toLongOrNull()
            ?.takeIf { it > 0L }
            ?.let { nowMs + it * 1000L },
    )
}

private fun decodeFormValue(raw: String): String =
    runCatching { java.net.URLDecoder.decode(raw.replace('+', ' '), "UTF-8") }.getOrDefault(raw)
