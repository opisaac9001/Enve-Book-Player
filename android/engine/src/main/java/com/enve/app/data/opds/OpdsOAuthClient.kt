package com.enve.app.data.opds

import com.enve.app.data.repository.isHttpUrl
import com.enve.core.data.util.optNonBlankString
import com.enve.core.data.util.optString
import com.enve.core.di.RefreshClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

data class OpdsOAuthToken(
    val accessToken: String,
    val refreshToken: String?,
    val expiresAtMs: Long?,
)

@Singleton
class OpdsOAuthClient @Inject constructor(
    @RefreshClient private val client: OkHttpClient,
) {

    suspend fun password(tokenUrl: String, username: String, password: String): OpdsOAuthToken? =
        withContext(Dispatchers.IO) { passwordBlocking(tokenUrl, username, password) }

    fun passwordBlocking(tokenUrl: String, username: String, password: String): OpdsOAuthToken? =
        exchange(tokenUrl) {
            add("grant_type", "password")
            add("username", username)
            add("password", password)
        }

    fun refreshBlocking(tokenUrl: String, refreshToken: String): OpdsOAuthToken? =
        exchange(tokenUrl) {
            add("grant_type", "refresh_token")
            add("refresh_token", refreshToken)
        }

    private fun exchange(tokenUrl: String, form: FormBody.Builder.() -> Unit): OpdsOAuthToken? {
        if (!isHttpUrl(tokenUrl)) return null
        val request = Request.Builder()
            .url(tokenUrl)
            .header("Accept", "application/json")
            .post(FormBody.Builder().apply(form).build())
            .build()
        val payload = try {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return null
                response.body?.string()
            }
        } catch (_: IOException) {
            return null
        }
        return parseOpdsOAuthToken(payload)
    }
}

internal fun parseOpdsOAuthToken(
    payload: String?,
    nowMs: Long = System.currentTimeMillis(),
): OpdsOAuthToken? {
    val text = payload?.trim()?.takeIf { it.startsWith("{") } ?: return null
    val root = runCatching { tokenJson.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
    val accessToken = root.optNonBlankString("access_token") ?: return null
    val tokenType = root.optString("token_type")
    if (tokenType != null && !tokenType.equals("bearer", ignoreCase = true)) return null
    val expiresIn = root.optString("expires_in")?.trim()?.toDoubleOrNull()?.takeIf { it > 0.0 }
    return OpdsOAuthToken(
        accessToken = accessToken,
        refreshToken = root.optNonBlankString("refresh_token"),
        expiresAtMs = expiresIn?.let { nowMs + (it * 1000L).toLong() },
    )
}

private val tokenJson = Json { ignoreUnknownKeys = true; isLenient = true }
