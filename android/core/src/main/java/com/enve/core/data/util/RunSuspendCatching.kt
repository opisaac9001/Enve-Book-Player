package com.enve.core.data.util

import kotlinx.coroutines.CancellationException

suspend inline fun <T> runSuspendCatching(crossinline block: suspend () -> T): Result<T> = try {
    Result.success(block())
} catch (error: CancellationException) {
    throw error
} catch (error: Exception) {
    Result.failure(error)
}
