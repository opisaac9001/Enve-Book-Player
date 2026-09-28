package com.enve.app.data.opds

import okhttp3.Authenticator
import okhttp3.CookieJar
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.ResponseBody
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.Header
import retrofit2.http.PUT
import retrofit2.http.Url
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Qualifier
import javax.inject.Singleton

@Qualifier
@Retention(AnnotationRetention.BINARY)
annotation class PrivateNetworkProgressionApi

@Qualifier
@Retention(AnnotationRetention.BINARY)
annotation class PublicNetworkProgressionApi

interface OpdsProgressionApi {

    @GET
    suspend fun fetch(
        @Url url: String,
        @Header("Accept") accept: String,
    ): Response<ResponseBody>

    @PUT
    suspend fun update(
        @Url url: String,
        @Header("Accept") accept: String,
        @Body body: RequestBody,
    ): Response<ResponseBody>
}

fun privateNetworkProgressionClient(shared: OkHttpClient): OkHttpClient =
    shared.newBuilder()
        .apply {
            interceptors().clear()
            networkInterceptors().clear()
        }
        .cache(null)
        .cookieJar(CookieJar.NO_COOKIES)
        .authenticator(Authenticator.NONE)
        .build()

fun publicNetworkProgressionClient(): OkHttpClient =
    OkHttpClient.Builder()
        .cookieJar(CookieJar.NO_COOKIES)
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

sealed interface OpdsProgressionResponse {
    data class Document(val document: OpdsProgressionDocument) : OpdsProgressionResponse

    data object Empty : OpdsProgressionResponse

    data object Unauthorized : OpdsProgressionResponse

    data class Conflict(val problem: OpdsProblemDetails?) : OpdsProgressionResponse

    data class Failure(val status: Int, val problem: OpdsProblemDetails?) : OpdsProgressionResponse
}

internal object OpdsProgressionResponses {

    fun forGet(status: Int, contentType: String?, payload: String?): OpdsProgressionResponse = when {
        status == HTTP_OK && payload.isNullOrBlank() -> OpdsProgressionResponse.Empty
        status == HTTP_OK -> document(status, contentType, payload)
        status == HTTP_UNAUTHORIZED -> OpdsProgressionResponse.Unauthorized
        else -> OpdsProgressionResponse.Failure(status, OpdsProgressionCodec.decodeProblem(payload))
    }

    fun forPut(status: Int, contentType: String?, payload: String?): OpdsProgressionResponse = when {
        status.isPutSuccess() -> document(status, contentType, payload)
        status == HTTP_UNAUTHORIZED -> OpdsProgressionResponse.Unauthorized
        status == HTTP_CONFLICT -> OpdsProgressionResponse.Conflict(OpdsProgressionCodec.decodeProblem(payload))
        else -> OpdsProgressionResponse.Failure(status, OpdsProgressionCodec.decodeProblem(payload))
    }

    private fun declaresProgressionDocument(contentType: String?): Boolean {
        val declared = contentType?.substringBefore(';')?.trim()?.takeIf { it.isNotEmpty() } ?: return true
        return declared.equals(OPDS_PROGRESSION_MEDIA_TYPE, ignoreCase = true)
    }

    private fun document(status: Int, contentType: String?, payload: String?): OpdsProgressionResponse {
        if (!declaresProgressionDocument(contentType)) return OpdsProgressionResponse.Failure(status, null)
        return OpdsProgressionCodec.decode(payload)
            ?.let(OpdsProgressionResponse::Document)
            ?: OpdsProgressionResponse.Failure(status, null)
    }

    private fun Int.isPutSuccess(): Boolean = this == HTTP_OK || this == HTTP_CREATED

    private const val HTTP_OK = 200
    private const val HTTP_CREATED = 201
    private const val HTTP_UNAUTHORIZED = 401
    private const val HTTP_CONFLICT = 409
}

@Singleton
class OpdsProgressionClient @Inject constructor(
    private val api: OpdsProgressionApi,
    @PrivateNetworkProgressionApi private val privateNetworkApi: OpdsProgressionApi,
    @PublicNetworkProgressionApi private val publicNetworkApi: OpdsProgressionApi,
) {

    suspend fun fetch(endpoint: OpdsProgressionEndpoint): OpdsProgressionResponse {
        val response = apiFor(endpoint).fetch(endpoint.url, OPDS_PROGRESSION_MEDIA_TYPE)
        return OpdsProgressionResponses.forGet(response.code(), response.contentType(), response.payload())
    }

    suspend fun update(
        endpoint: OpdsProgressionEndpoint,
        document: OpdsProgressionDocument,
    ): OpdsProgressionResponse {
        val body = OpdsProgressionCodec.encode(document).toRequestBody(progressionMediaType)
        val response = apiFor(endpoint).update(endpoint.url, OPDS_PROGRESSION_MEDIA_TYPE, body)
        return OpdsProgressionResponses.forPut(response.code(), response.contentType(), response.payload())
    }

    private fun apiFor(endpoint: OpdsProgressionEndpoint): OpdsProgressionApi =
        when (endpoint.transport) {
            OpdsProgressionTransport.SCOPED -> api
            OpdsProgressionTransport.PRIVATE_NETWORK -> privateNetworkApi
            OpdsProgressionTransport.PUBLIC_NETWORK -> publicNetworkApi
        }

    private fun Response<ResponseBody>.contentType(): String? = headers()["Content-Type"]

    private fun Response<ResponseBody>.payload(): String? =
        (if (isSuccessful) body() else errorBody())?.use { it.string() }

    private companion object {
        val progressionMediaType = OPDS_PROGRESSION_MEDIA_TYPE.toMediaType()
    }
}
