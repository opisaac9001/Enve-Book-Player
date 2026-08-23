package com.enve.app.data.sync

import com.enve.core.data.sync.KOReaderProgress
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class KOReaderHubClient @Inject constructor(
    private val okHttpClient: OkHttpClient,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    sealed class KOReaderError(message: String) : RuntimeException(message) {
        object Unauthorized : KOReaderError("Incorrect username or password.")
        data class Server(val code: Int, val serverMessage: String) :
            KOReaderError("Server error $code: $serverMessage")
    }

    suspend fun authorize(baseUrl: String, username: String, passwordHash: String): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                val request = Request.Builder()
                    .url("$baseUrl/users/auth")
                    .get()
                    .kosyncHeaders(username, passwordHash)
                    .build()
                okHttpClient.newCall(request).execute().use { response ->
                    validateStatus(response.code, response.peekBodyString())
                }
            }
        }

    suspend fun register(baseUrl: String, username: String, passwordHash: String): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                val payload = buildJsonObject {
                    put("username", JsonPrimitive(username))
                    put("password", JsonPrimitive(passwordHash))
                }
                val request = Request.Builder()
                    .url("$baseUrl/users/create")
                    .post(json.encodeToString(JsonObject.serializer(), payload)
                        .toRequestBody(JSON_MEDIA))
                    .header("Accept", ACCEPT_HEADER)
                    .header("Content-Type", "application/json")
                    .build()
                okHttpClient.newCall(request).execute().use { response ->
                    if (response.code == 201) return@use
                    val body = response.peekBodyString()
                    val serverMessage = runCatching {
                        json.parseToJsonElement(body).let { el ->
                            (el as? JsonObject)?.get("message")
                                ?.let { (it as? JsonPrimitive)?.content }
                        }
                    }.getOrNull()
                    throw KOReaderError.Server(response.code, serverMessage ?: "Registration failed")
                }
            }
        }

    suspend fun pushProgress(
        baseUrl: String,
        username: String,
        passwordHash: String,
        document: String,
        progress: String,
        percentage: Double,
        device: String,
        deviceId: String,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val payload = buildJsonObject {
                put("document", JsonPrimitive(document))
                put("progress", JsonPrimitive(progress))
                put("percentage", JsonPrimitive(percentage.coerceIn(0.0, 1.0)))
                put("device", JsonPrimitive(device))
                put("device_id", JsonPrimitive(deviceId))
            }
            val request = Request.Builder()
                .url("$baseUrl/syncs/progress")
                .put(json.encodeToString(JsonObject.serializer(), payload).toRequestBody(JSON_MEDIA))
                .kosyncHeaders(username, passwordHash)
                .header("Content-Type", "application/json")
                .build()
            okHttpClient.newCall(request).execute().use { response ->
                validateStatus(response.code, response.peekBodyString())
            }
        }
    }

    suspend fun fetchProgress(
        baseUrl: String,
        username: String,
        passwordHash: String,
        document: String,
    ): Result<KOReaderProgress?> = withContext(Dispatchers.IO) {
        runCatching {
            val request = Request.Builder()
                .url("$baseUrl/syncs/progress/$document")
                .get()
                .kosyncHeaders(username, passwordHash)
                .build()
            okHttpClient.newCall(request).execute().use { response ->
                when {
                    response.code == 404 -> null
                    response.isSuccessful -> {
                        val body = response.body?.string().orEmpty()
                        if (body.isBlank()) null
                        else json.decodeFromString(KOReaderProgress.serializer(), body)
                            .takeIf { it.document.isNotEmpty() }
                    }
                    else -> {
                        validateStatus(response.code, body = "")
                        null
                    }
                }
            }
        }
    }

    private fun validateStatus(code: Int, body: String) {
        when (code) {
            200, 201, 202 -> return
            401, 402 -> throw KOReaderError.Unauthorized
            else -> throw KOReaderError.Server(code, body.ifBlank { "HTTP $code" })
        }
    }

    private fun okhttp3.Response.peekBodyString(): String =
        runCatching { peekBody(8_192).string() }.getOrDefault("")

    private fun Request.Builder.kosyncHeaders(username: String, passwordHash: String): Request.Builder =
        header("x-auth-user", username)
            .header("x-auth-key", passwordHash)
            .header("Accept", ACCEPT_HEADER)

    private companion object {
        const val ACCEPT_HEADER = "application/vnd.koreader.v1+json"
        val JSON_MEDIA = "application/json".toMediaType()
    }
}
