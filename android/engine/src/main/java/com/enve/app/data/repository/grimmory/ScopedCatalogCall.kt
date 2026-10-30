package com.enve.app.data.repository.grimmory

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import retrofit2.Call
import retrofit2.Response

internal suspend fun <T> Call<T>.catalogResponse(): Response<T> = withContext(Dispatchers.IO) {
    suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        try {
            val response = execute()
            if (continuation.isActive) continuation.resume(response) else response.errorBody()?.close()
        } catch (error: Exception) {
            if (continuation.isActive) continuation.resumeWithException(error)
        }
    }
}
