package com.enve.core.data.remote

import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class JsonSafetyInterceptor @Inject constructor() : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val response = chain.proceed(request)

        val actualRequest = response.request
        val acceptHeader = actualRequest.header("Accept")
        val isJsonExpected = acceptHeader != null && acceptHeader.contains("application/json")

        if (isJsonExpected) {
            val contentType = response.header("Content-Type")
            if (contentType != null && (contentType.contains("text/html") || contentType.contains("application/xhtml+xml"))) {
                val location = response.header("Location")
                val code = response.code
                response.close()

                throw IOException(jsonSafetyHtmlMismatchMessage(code, actualRequest.url.host, location))
            }
        }

        return response
    }
}

internal fun jsonSafetyHtmlMismatchMessage(code: Int, host: String, location: String?): String =
    when (code) {
        401, 403 -> "Session expired. Please sign in again."
        404 -> "The requested data was not found (404). Your server URL might be incorrect."
        else -> {
            val redirectHint = if (!location.isNullOrBlank()) {
                " The server redirected this request to ${location.take(120)}."
            } else {
                ""
            }
            "The server at $host returned a web page instead of API data.$redirectHint Sign in again and confirm the server URL points to the correct API host."
        }
    }
