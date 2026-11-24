package com.enve.app.data.repository

import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.TorBoxDownloadDto
import com.enve.app.data.remote.dto.TorBoxListResponseDto
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import okhttp3.Credentials
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class TorBoxTransport internal constructor(private val api: GrimmoryApi, private val client: OkHttpClient) {
    @Inject constructor(api: GrimmoryApi) : this(api, OkHttpClient())

    private val json = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
    }

    fun baseUrl(serverUrl: String): String =
        serverUrl.ifBlank { DEFAULT_BASE_URL }.trimEnd('/')

    suspend fun verifyToken(serverUrl: String, accessToken: String) {
        val url = baseUrl(serverUrl).toHttpUrlOrNull()?.newBuilder()
            ?.addPathSegments("torrents/mylist")
            ?.addQueryParameter("limit", "1")
            ?.build() ?: throw Exception("TorBox server URL is invalid")
        retryTorBoxRequest {
            val request = Request.Builder().url(url)
                .header("Authorization", "Bearer $accessToken").build()
            val body = client.newCall(request).torBoxResponseBody()
            json.decodeFromString<TorBoxListResponseDto>(body).requireTorBoxList()
        }
    }

    suspend fun downloads(baseUrl: String, typePath: String, offset: Int, fresh: Boolean): List<TorBoxDownloadDto>? {
        val url = buildProviderUrl(baseUrl, typePath, "mylist")
            ?.toHttpUrlOrNull()
            ?.newBuilder()
            ?.addQueryParameter("limit", PAGE_SIZE.toString())
            ?.addQueryParameter("offset", offset.toString())
            ?.apply { if (fresh) addQueryParameter("bypass_cache", "true") }
            ?.build()
            ?.toString()
            ?: return null
        return retryTorBoxRequest {
            val response = api.torBoxList(url)
            if (!response.isSuccessful) {
                response.errorBody()?.close()
                throw TorBoxRequestException(response.code(), response.headers()["Retry-After"])
            }
            response.body()?.requireTorBoxList() ?: throw TorBoxRequestException(502)
        }
    }

    fun downloadUrl(
        baseUrl: String,
        token: String,
        typePath: String,
        idParameter: String,
        itemId: String,
        fileId: String,
    ): String? {
        return buildProviderUrl(baseUrl, typePath, "requestdl")
            ?.toHttpUrlOrNull()
            ?.newBuilder()
            ?.addQueryParameter("token", token)
            ?.addQueryParameter(idParameter, itemId)
            ?.addQueryParameter("file_id", fileId)
            ?.addQueryParameter("redirect", "true")
            ?.build()
            ?.toString()
    }

    suspend fun webDavListing(url: String, token: String): String = retryTorBoxRequest {
        val request = Request.Builder()
            .url(url)
            .method("PROPFIND", webDavPropfindBody())
            .header("Depth", "1")
            .header("Authorization", Credentials.basic(WEBDAV_USERNAME, token))
            .build()
        client.newCall(request).torBoxResponseBody()
    }

    fun webDavCredentialUrl(url: String, token: String): String? {
        val parsed = url.toHttpUrlOrNull() ?: return null
        return parsed.newBuilder()
            .username(WEBDAV_USERNAME)
            .password(token)
            .build()
            .toString()
    }

    companion object {
        const val WEBDAV_BASE_URL = "https://webdav.torbox.app/"
        private const val DEFAULT_BASE_URL = "https://api.torbox.app/v1/api"
        private const val WEBDAV_USERNAME = "torbox"
        private const val PAGE_SIZE = 1000
    }
}
