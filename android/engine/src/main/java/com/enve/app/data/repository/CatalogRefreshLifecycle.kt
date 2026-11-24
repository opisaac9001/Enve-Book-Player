package com.enve.app.data.repository

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import com.enve.core.data.provider.CatalogFailureKind
import com.enve.core.data.provider.CatalogImportException
import java.io.IOException
import javax.inject.Inject
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first

class CatalogRefreshLifecycle internal constructor(
    private val awaitForeground: suspend () -> Unit,
    private val awaitBackground: suspend () -> Unit,
) {
    @Inject constructor() : this(
        { ProcessLifecycleOwner.get().lifecycle.currentStateFlow.first { it.isAtLeast(Lifecycle.State.STARTED) }; Unit },
        { ProcessLifecycleOwner.get().lifecycle.currentStateFlow.first { !it.isAtLeast(Lifecycle.State.STARTED) }; Unit },
    )

    suspend fun <T> load(request: suspend () -> Result<T>): Result<T> {
        awaitForeground()
        val (result, backgrounded) = coroutineScope {
            val background = async(start = CoroutineStart.UNDISPATCHED) { awaitBackground() }
            try {
                val result = request()
                result to background.isCompleted
            } finally {
                background.cancel()
            }
        }
        val error = result.exceptionOrNull()
        val networkFailure = error is IOException || error is CatalogImportException &&
            error.reports.any { report -> report.failures.any { it.kind == CatalogFailureKind.NETWORK } }
        if (!backgrounded || !networkFailure) return result
        awaitForeground()
        return request()
    }
}
