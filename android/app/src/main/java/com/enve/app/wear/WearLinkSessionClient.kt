package com.enve.app.wear

import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.di.RefreshClient
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

data class WearLinkSession(
    val accessToken: String,
    val refreshToken: String?,
)

@Singleton
class WearLinkSessionClient @Inject constructor(
    @RefreshClient baseClient: OkHttpClient,
) {
    private val client = baseClient.newBuilder()
        .followRedirects(false)
        .followSslRedirects(false)
        .build()
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun create(connection: ProviderConnection, password: String): WearLinkSession = withContext(Dispatchers.IO) {
        require(password.isNotBlank()) { "Enter the password for this connection." }
        val base = (connection.serverUrl.trim().trimEnd('/') + "/").toHttpUrl()
        require(base.username.isEmpty() && base.password.isEmpty() && base.query == null && base.fragment == null) {
            "The server address contains unsupported sign-in details."
        }
        val path = when (connection.source) {
            BookSource.AUDIOBOOKSHELF -> "login"
            BookSource.GRIMMORY -> "api/v1/auth/login"
            else -> error("${connection.source.displayName} is not supported on the watch yet.")
        }
        val body = buildJsonObject {
            put("username", connection.username)
            put("password", password)
        }.toString().toRequestBody(JSON)
        val request = Request.Builder()
            .url(base.resolve(path) ?: error("The server address is invalid."))
            .post(body)
            .apply {
                if (connection.source == BookSource.AUDIOBOOKSHELF) header("x-return-tokens", "true")
            }
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                error(if (response.code == 401 || response.code == 403) "The username or password was rejected." else "The server couldn’t create a watch session (${response.code}).")
            }
            val payload = runCatching {
                json.parseToJsonElement(response.body?.string().orEmpty()).jsonObject
            }.getOrElse { error("The server returned an invalid watch session.") }
            val user = payload["user"]?.jsonObject
            val accessToken = user.string("accessToken")
                .ifBlank { user.string("token") }
                .ifBlank { payload.string("accessToken") }
            val refreshToken = user.string("refreshToken")
                .ifBlank { payload.string("refreshToken") }
                .takeIf { it.isNotBlank() }
            if (accessToken.isBlank() || refreshToken.isNullOrBlank()) {
                error("The server didn’t return a renewable watch session.")
            }
            WearLinkSession(accessToken, refreshToken)
        }
    }

    private fun kotlinx.serialization.json.JsonObject?.string(key: String): String =
        this?.get(key)?.jsonPrimitive?.contentOrNull.orEmpty()

    private companion object {
        val JSON = "application/json".toMediaType()
    }
}
