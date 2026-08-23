package com.enve.app.data.sync

import com.enve.core.auth.CredentialVault
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class KosyncClient @Inject constructor(
    private val okHttpClient: OkHttpClient,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    suspend fun authenticate(
        baseUrl: String,
        username: String,
        password: String,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val request = Request.Builder()
                .url("${baseUrl.trimEnd('/')}/api/koreader/users/auth")
                .get()
                .kosyncHeaders(username, password)
                .build()

            okHttpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    error("Kosync auth failed: ${response.code}")
                }
            }
        }
    }

    suspend fun pushProgress(
        baseUrl: String,
        username: String,
        password: String,
        request: KosyncProgressRequest,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val body = json.encodeToString(KosyncProgressRequest.serializer(), request)
                .toRequestBody("application/json".toMediaType())

            val httpRequest = Request.Builder()
                .url("${baseUrl.trimEnd('/')}/api/koreader/syncs/progress")
                .put(body)
                .kosyncHeaders(username, password)
                .build()

            okHttpClient.newCall(httpRequest).execute().use { response ->
                if (!response.isSuccessful) {
                    throw KosyncHttpException(response.code, "Push progress failed: ${response.code}")
                }
            }
        }
    }

    suspend fun pullProgress(
        baseUrl: String,
        username: String,
        password: String,
        documentHash: String,
    ): Result<KosyncProgressResponse?> = withContext(Dispatchers.IO) {
        runCatching {
            val httpRequest = Request.Builder()
                .url("${baseUrl.trimEnd('/')}/api/koreader/syncs/progress/$documentHash")
                .get()
                .kosyncHeaders(username, password)
                .build()

            okHttpClient.newCall(httpRequest).execute().use { response ->
                when {
                    response.isSuccessful -> {
                        val bodyStr = response.body?.string() ?: return@use null
                        json.decodeFromString(KosyncProgressResponse.serializer(), bodyStr)
                    }
                    response.code == 404 ->
                        throw KosyncHttpException(404, "No progress for hash=$documentHash")
                    else -> null
                }
            }
        }
    }

    private fun Request.Builder.kosyncHeaders(username: String, password: String): Request.Builder =
        header("x-auth-user", username)
            .header("x-auth-key", md5Hash(password))
            .header("Accept", ACCEPT_HEADER)

    companion object {
        private const val ACCEPT_HEADER = "application/vnd.koreader.v1+json"
    }
}

class KosyncHttpException(val statusCode: Int, message: String) : RuntimeException(message)

@Serializable
data class KosyncProgressRequest(
    val document: String,
    @SerialName("progress")
    val positionData: String,
    val percentage: Float,
    val device: String,
    @SerialName("device_id")
    val deviceId: String,
)

@Serializable
data class KosyncProgressResponse(
    val document: String? = null,
    @SerialName("progress")
    val positionData: String? = null,
    val percentage: Float? = null,
    val device: String? = null,
    @SerialName("device_id")
    val deviceId: String? = null,
    val timestamp: Long? = null,
)
