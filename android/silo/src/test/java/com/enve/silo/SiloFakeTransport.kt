package com.enve.silo

import com.enve.silo.api.SiloApi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

data class SiloCall(val method: String, val url: HttpUrl, val headers: Headers, val body: String) {
    val path: String get() = url.encodedPath
    fun query(name: String): String? = url.queryParameter(name)
    fun json(): JsonObject = Json.parseToJsonElement(body).jsonObject
}

data class SiloReply(val code: Int, val body: String = "", val contentType: String = "application/json")

fun problem(id: String, status: Int) = SiloReply(
    status,
    """{"type":"https://siloserver.org/docs/api/v2/problems/$id","title":"t","status":$status,"detail":"d","instance":"urn:silo:request:1"}""",
    "application/problem+json",
)

private val transportJson = Json {
                ignoreUnknownKeys = true
                isLenient = true
                coerceInputValues = true
                encodeDefaults = true
            }

class SiloFakeTransport(private val route: (SiloCall) -> SiloReply) : Interceptor {
    val calls = mutableListOf<SiloCall>()

    val api: SiloApi = Retrofit.Builder()
        .baseUrl("http://localhost/")
        .client(OkHttpClient.Builder().addInterceptor(this).build())
        .addConverterFactory(
            transportJson.asConverterFactory("application/json".toMediaType()),
        )
        .build()
        .create(SiloApi::class.java)

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val buffer = Buffer().also { request.body?.writeTo(it) }
        val call = SiloCall(request.method, request.url, request.headers, buffer.readUtf8())
        synchronized(calls) { calls += call }
        val reply = route(call)
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(reply.code)
            .message("status")
            .body(reply.body.toResponseBody(reply.contentType.toMediaType()))
            .build()
    }
}
