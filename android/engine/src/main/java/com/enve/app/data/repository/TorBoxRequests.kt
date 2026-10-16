package com.enve.app.data.repository

import com.enve.app.data.remote.dto.TorBoxDownloadDto
import com.enve.app.data.remote.dto.TorBoxListResponseDto
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Response
import java.io.IOException
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class TorBoxRequestException(val status: Int, val retryAfter: String? = null) : Exception(
    when (status) {
        401, 403 -> "TorBox rejected the API key. Check the source settings."
        429 -> "TorBox is limiting requests. Please refresh again later."
        else -> "TorBox could not load the library. Please try again."
    },
)

internal fun TorBoxListResponseDto.requireTorBoxList(): List<TorBoxDownloadDto> {
    if (error == "ITEM_NOT_FOUND" && data.isNullOrEmpty()) return emptyList()
    if (!success) throw TorBoxRequestException(
        when (error) {
            "BAD_TOKEN", "INVALID_TOKEN", "AUTH_ERROR", "UNAUTHORIZED" -> 401
            "RATE_LIMITED", "RATE_LIMIT_EXCEEDED" -> 429
            else -> 502
        },
    )
    return data ?: throw TorBoxRequestException(502)
}

internal fun torBoxRetryDelay(error: Exception, attempt: Int, nowMs: Long = System.currentTimeMillis()): Long? {
    if (attempt >= 2) return null
    if (error is TorBoxRequestException) {
        if (error.status != 429 && error.status !in 500..599) return null
        error.retryAfter?.let { header ->
            val milliseconds = header.toLongOrNull()?.takeIf { it >= 0 }?.let { seconds ->
                if (seconds > 10) return null
                seconds * 1000
            } ?: runCatching {
                ZonedDateTime.parse(header, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli() - nowMs
            }.getOrNull()
            if (milliseconds != null) return milliseconds.coerceAtLeast(0).takeIf { it <= 10_000 }
        }
    } else if (error !is IOException) return null
    return 500L shl attempt
}

internal suspend fun <T> retryTorBoxRequest(request: suspend () -> T): T {
    var attempt = 0
    while (true) {
        try {
            return request()
        } catch (error: Exception) {
            val wait = torBoxRetryDelay(error, attempt++) ?: throw error
            delay(wait)
        }
    }
}

internal suspend fun Call.torBoxResponseBody(): String = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (continuation.isActive) continuation.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            try {
                val listing = response.use {
                    if (!it.isSuccessful) throw TorBoxRequestException(it.code, it.header("Retry-After"))
                    it.body?.string() ?: throw TorBoxRequestException(502)
                }
                if (continuation.isActive) continuation.resume(listing)
            } catch (error: Exception) {
                if (continuation.isActive) continuation.resumeWithException(error)
            }
        }
    })
}
