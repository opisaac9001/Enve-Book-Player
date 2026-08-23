package com.enve.app.data.repository

import com.enve.core.data.local.PreferencesManager
import com.enve.app.data.remote.dto.JellyfinAuthenticateWithQuickConnectRequest
import com.enve.app.data.remote.dto.JellyfinAuthenticationResult
import com.enve.app.data.remote.dto.JellyfinQuickConnectResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class JellyfinRepository @Inject constructor(
    private val httpClient: OkHttpClient,
    private val preferencesManager: PreferencesManager,
) {
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }
    private val jsonMediaType = "application/json".toMediaType()

    private val rawClient: OkHttpClient by lazy {
        httpClient.newBuilder()
            .also { b ->
                b.interceptors().removeAll { true }
                b.networkInterceptors().removeAll { true }
            }
            .build()
    }

    private fun authHeader(): String {
        val deviceId = preferencesManager.getOrCreatePlexClientIdentifierSync()
        val deviceName = (android.os.Build.MODEL ?: "Android Device").take(64)
        return buildString {
            append("MediaBrowser Client=\"Enve\"")
            append(", Device=\"")
            append(deviceName.replace("\"", ""))
            append("\"")
            append(", DeviceId=\"")
            append(deviceId)
            append("\"")
            append(", Version=\"1.0\"")
        }
    }

    private fun resolveUrl(serverUrl: String, path: String): String {
        val base = serverUrl.trim().trimEnd('/')
        return "$base$path"
    }

    suspend fun isQuickConnectEnabled(serverUrl: String): Result<Boolean> = runCatching {
        withContext(Dispatchers.IO) {
            val url = resolveUrl(serverUrl, "/QuickConnect/Enabled").toHttpUrlOrNull()
                ?: error("Invalid Jellyfin server URL")
            val request = Request.Builder()
                .url(url)
                .header("Authorization", authHeader())
                .header("Accept", "application/json")
                .get()
                .build()
            rawClient.newCall(request).execute().use { resp ->
                if (!resp.isSuccessful) {

                    if (resp.code == 404) return@withContext false
                    error("Quick Connect availability check failed: HTTP ${resp.code}")
                }
                val body = resp.body?.string()?.trim().orEmpty()
                body.equals("true", ignoreCase = true)
            }
        }
    }

    suspend fun initiateQuickConnect(serverUrl: String): Result<JellyfinQuickConnectResult> = runCatching {
        withContext(Dispatchers.IO) {
            val url = resolveUrl(serverUrl, "/QuickConnect/Initiate").toHttpUrlOrNull()
                ?: error("Invalid Jellyfin server URL")

            fun send(method: String): okhttp3.Response {
                val builder = Request.Builder()
                    .url(url)
                    .header("Authorization", authHeader())
                    .header("Accept", "application/json")
                if (method == "POST") {

                    builder.post("".toRequestBody(jsonMediaType))
                } else {
                    builder.get()
                }
                return rawClient.newCall(builder.build()).execute()
            }
            send("POST").use { post ->
                if (post.code == 405) {
                    send("GET").use { get ->
                        if (!get.isSuccessful) {
                            error("Quick Connect initiate failed: HTTP ${get.code}")
                        }
                        json.decodeFromString(
                            JellyfinQuickConnectResult.serializer(),
                            get.body?.string().orEmpty(),
                        )
                    }
                } else {
                    if (post.code == 401) {
                        error("Quick Connect is disabled on this Jellyfin server. Enable it in Dashboard → General.")
                    }
                    if (!post.isSuccessful) {
                        error("Quick Connect initiate failed: HTTP ${post.code}")
                    }
                    json.decodeFromString(
                        JellyfinQuickConnectResult.serializer(),
                        post.body?.string().orEmpty(),
                    )
                }
            }
        }
    }

    suspend fun pollQuickConnect(serverUrl: String, secret: String): Result<JellyfinQuickConnectResult> = runCatching {
        withContext(Dispatchers.IO) {
            val url = resolveUrl(serverUrl, "/QuickConnect/Connect").toHttpUrlOrNull()
                ?.newBuilder()
                ?.addQueryParameter("Secret", secret)
                ?.build()
                ?: error("Invalid Jellyfin server URL")
            val request = Request.Builder()
                .url(url)
                .header("Authorization", authHeader())
                .header("Accept", "application/json")
                .get()
                .build()
            rawClient.newCall(request).execute().use { resp ->
                when (resp.code) {
                    in 200..299 -> json.decodeFromString(
                        JellyfinQuickConnectResult.serializer(),
                        resp.body?.string().orEmpty(),
                    )
                    404 -> error("Quick Connect request expired. Start over.")
                    401 -> error("Quick Connect was disabled while waiting. Try again.")
                    else -> error("Quick Connect poll failed: HTTP ${resp.code}")
                }
            }
        }
    }

    suspend fun authenticateWithQuickConnect(
        serverUrl: String,
        secret: String,
    ): Result<JellyfinAuthenticationResult> = runCatching {
        withContext(Dispatchers.IO) {
            val url = resolveUrl(serverUrl, "/Users/AuthenticateWithQuickConnect").toHttpUrlOrNull()
                ?: error("Invalid Jellyfin server URL")
            val body = json.encodeToString(
                JellyfinAuthenticateWithQuickConnectRequest.serializer(),
                JellyfinAuthenticateWithQuickConnectRequest(Secret = secret),
            ).toRequestBody(jsonMediaType)
            val request = Request.Builder()
                .url(url)
                .header("Authorization", authHeader())
                .header("Accept", "application/json")
                .post(body)
                .build()
            rawClient.newCall(request).execute().use { resp ->
                if (!resp.isSuccessful) {
                    error("Quick Connect authenticate failed: HTTP ${resp.code}")
                }
                json.decodeFromString(
                    JellyfinAuthenticationResult.serializer(),
                    resp.body?.string().orEmpty(),
                )
            }
        }
    }
}
