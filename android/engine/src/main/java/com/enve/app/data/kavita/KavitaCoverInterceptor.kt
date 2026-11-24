package com.enve.app.data.kavita

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.CacheControl
import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class KavitaCoverInterceptor @Inject constructor() : Interceptor {
    private val imageKeys = LinkedHashMap<String, String>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val original = chain.request()
        if (original.url.queryParameter("enveCoverRevision") == null) return chain.proceed(original)
        val request = original.newBuilder().url(original.url.newBuilder().apply {
            original.url.queryParameterNames.filter { it.equals("apiKey", ignoreCase = true) }
                .forEach(::removeAllQueryParameters)
        }.build()).build()
        val endpoint = request.url.encodedPath.lastIndexOf("/api/image/", ignoreCase = true)
        if (endpoint < 0) return chain.proceed(request)
        val directKey = request.header("X-API-Key")?.takeIf(String::isNotBlank)
        val bearer = request.header("Authorization")?.takeIf { it.startsWith("Bearer ") }
        if (directKey == null && bearer == null) return chain.proceed(request)
        val accountUrl = request.url.newBuilder()
            .encodedPath(request.url.encodedPath.take(endpoint) + "/api/Account")
            .query(null).build()
        val cacheKey = "$accountUrl\n${directKey ?: bearer}"
        var key = synchronized(imageKeys) { imageKeys[cacheKey] }
        if (key == null) {
            val headerResponse = chain.proceed(request)
            if (headerResponse.code != 400) return headerResponse
            headerResponse.close()
        }
        if (key == null) {
            val value = directKey ?: run {
                val account = request.newBuilder().url(accountUrl).get()
                    .header("Accept", "application/json")
                    .cacheControl(CacheControl.Builder().noCache().noStore().build()).build()
                chain.proceed(account).use { response ->
                    if (!response.isSuccessful) throw IOException("Kavita image credentials failed (HTTP ${response.code})")
                    val body = response.body?.string() ?: throw IOException("Kavita image credentials are missing")
                    try {
                        Json.parseToJsonElement(body).jsonObject["apiKey"]?.jsonPrimitive?.content
                            ?.takeIf(String::isNotBlank) ?: throw IOException("Kavita image API key is missing")
                    } catch (error: IllegalArgumentException) {
                        throw IOException("Kavita image credentials are invalid", error)
                    }
                }
            }
            key = synchronized(imageKeys) {
                imageKeys[cacheKey] ?: value.also {
                    if (imageKeys.size >= 16) imageKeys.remove(imageKeys.keys.first())
                    imageKeys[cacheKey] = it
                }
            }
        }
        val imageUrl = request.url.newBuilder().apply {
            request.url.queryParameterNames.filter { it.equals("apiKey", ignoreCase = true) }
                .forEach(::removeAllQueryParameters)
            addQueryParameter("apiKey", key)
        }.build()
        val response = chain.proceed(request.newBuilder().url(imageUrl)
            .cacheControl(CacheControl.Builder().noCache().noStore().build()).build())
        if (response.code in setOf(400, 401, 403)) synchronized(imageKeys) { imageKeys.remove(cacheKey) }
        return response
    }
}
