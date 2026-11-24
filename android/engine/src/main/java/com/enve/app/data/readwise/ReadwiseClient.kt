package com.enve.app.data.readwise

import com.enve.engine.readwise.ReadwiseFailure
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class ReadwiseRequestException(
    val failure: ReadwiseFailure,
    val retryAfterSeconds: Long? = null,
    val retryable: Boolean = failure in RETRYABLE,
) : Exception(failure.name) {
    private companion object {
        val RETRYABLE = setOf(ReadwiseFailure.RATE_LIMITED, ReadwiseFailure.SERVER, ReadwiseFailure.NETWORK)
    }
}

@Serializable
internal data class ReadwiseCreatedBook(
    val id: Long,
    @SerialName("modified_highlights") val modifiedHighlights: List<Long> = emptyList(),
)

@Serializable
internal data class ReadwiseRemoteHighlight(val id: Long, val text: String)

@Serializable
internal data class ReadwiseHighlightPage(val results: List<ReadwiseRemoteHighlight>, val next: String? = null)

@Singleton
class ReadwiseClient internal constructor(
    private val client: OkHttpClient,
    private val origin: HttpUrl,
) {
    @Inject constructor() : this(readwiseHttpClient(), READWISE_ORIGIN.toHttpUrl())

    private val json = Json { ignoreUnknownKeys = true }

    internal suspend fun checkToken(token: String) {
        val result = exchange(authorized(token).url(origin.resolve(AUTH_PATH)!!).get().build())
        expect(result, 204)
    }

    internal suspend fun createHighlight(token: String, highlight: ReadwiseHighlightPayload): List<ReadwiseCreatedBook> {
        val body = json.encodeToString(ReadwiseCreateHighlightsRequest.serializer(), ReadwiseCreateHighlightsRequest(listOf(highlight)))
        val result = exchange(
            authorized(token).url(origin.resolve(HIGHLIGHTS_PATH)!!).post(body.toRequestBody(JSON_MEDIA_TYPE)).build(),
        )
        expect(result, 200)
        return decode(ListSerializer(ReadwiseCreatedBook.serializer()), result.body)
    }

    internal suspend fun updateHighlight(token: String, highlightId: Long, update: ReadwiseHighlightUpdate): Boolean {
        val body = json.encodeToString(ReadwiseHighlightUpdate.serializer(), update)
        val url = origin.resolve("$HIGHLIGHTS_PATH$highlightId/")!!
        val result = exchange(authorized(token).url(url).patch(body.toRequestBody(JSON_MEDIA_TYPE)).build())
        if (result.code == 404) return false
        expect(result, 200)
        if (decode(ReadwiseRemoteHighlight.serializer(), result.body).id != highlightId) throw readwiseUnconfirmed()
        return true
    }

    internal suspend fun highlightsPage(token: String, bookId: Long, page: Int): ReadwiseHighlightPage {
        val url = origin.resolve(HIGHLIGHTS_PATH)!!.newBuilder()
            .addQueryParameter("book_id", bookId.toString())
            .addQueryParameter("page_size", PAGE_SIZE.toString())
            .addQueryParameter("page", page.toString())
            .build()
        val result = exchange(authorized(token).url(url).get().build())
        expect(result, 200)
        return decode(ReadwiseHighlightPage.serializer(), result.body)
    }

    private fun authorized(token: String) = Request.Builder().header(AUTHORIZATION, "Token $token")

    private fun expect(result: HttpResult, code: Int) {
        readwiseFailureFor(result.code, result.retryAfter)?.let { throw it }
        if (result.code != code) throw readwiseUnconfirmed()
    }

    private fun <T> decode(deserializer: DeserializationStrategy<T>, body: String): T =
        try {
            json.decodeFromString(deserializer, body)
        } catch (_: IllegalArgumentException) {
            throw readwiseUnconfirmed()
        }

    private class HttpResult(val code: Int, val retryAfter: String?, val body: String)

    private suspend fun exchange(request: Request): HttpResult =
        suspendCancellableCoroutine { continuation ->
            val call = client.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    continuation.resumeWithException(e)
                }

                override fun onResponse(call: Call, response: Response) {
                    val result = try {
                        response.use { HttpResult(it.code, it.header(RETRY_AFTER), it.body?.string().orEmpty()) }
                    } catch (e: IOException) {
                        continuation.resumeWithException(e)
                        return
                    }
                    continuation.resume(result)
                }
            })
        }

    private companion object {
        const val PAGE_SIZE = 1000
        const val READWISE_ORIGIN = "https://readwise.io/"
        const val AUTH_PATH = "api/v2/auth/"
        const val HIGHLIGHTS_PATH = "api/v2/highlights/"
        const val AUTHORIZATION = "Authorization"
        const val RETRY_AFTER = "Retry-After"
        val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
    }
}

internal fun readwiseUnconfirmed() = ReadwiseRequestException(ReadwiseFailure.SERVER, retryable = false)

internal fun readwiseHttpClient(): OkHttpClient = OkHttpClient.Builder()
    .followRedirects(false)
    .followSslRedirects(false)
    .retryOnConnectionFailure(false)
    .connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(30, TimeUnit.SECONDS)
    .writeTimeout(30, TimeUnit.SECONDS)
    .build()

internal fun readwiseFailureFor(code: Int, retryAfter: String?): ReadwiseRequestException? = when {
    code in 200..299 -> null
    code in 300..399 -> readwiseUnconfirmed()
    code == 401 || code == 403 -> ReadwiseRequestException(ReadwiseFailure.INVALID_TOKEN)
    code == 429 -> ReadwiseRequestException(
        ReadwiseFailure.RATE_LIMITED,
        retryAfter?.trim()?.toLongOrNull()?.coerceAtLeast(0),
    )
    code in 400..499 -> ReadwiseRequestException(ReadwiseFailure.REJECTED)
    else -> ReadwiseRequestException(ReadwiseFailure.SERVER)
}
