package com.enve.app.data.repository.grimmory

import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.GrimmoryAppBookProgressDto
import com.enve.core.data.util.runSuspendCatching
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

data class GrimmoryListProgress(
    val bookId: String,
    val readProgress: Float?,
    val lastReadTime: String,
)

@Singleton
class GrimmoryListProgressResolver @Inject constructor(
    private val api: GrimmoryApi,
) {
    private val resolved = ConcurrentHashMap<String, Float>()

    suspend fun fractions(scope: String, rows: List<GrimmoryListProgress>): Map<String, Float> =
        resolveGrimmoryListProgress(scope, rows, resolved) { bookId ->
            api.getAppBookProgress(bookId).takeIf { it.isSuccessful }?.body()
        }
}

private const val MAX_CONCURRENT_PROGRESS_FETCHES = 4

internal suspend fun resolveGrimmoryListProgress(
    scope: String,
    rows: List<GrimmoryListProgress>,
    resolved: MutableMap<String, Float>,
    fetchProgress: suspend (String) -> GrimmoryAppBookProgressDto?,
): Map<String, Float> = coroutineScope {
    val fractions = HashMap<String, Float>(rows.size)
    val ambiguous = mutableListOf<Pair<GrimmoryListProgress, String>>()
    rows.forEach { row ->
        val raw = row.readProgress
        when {
            raw == null || raw <= 0f -> fractions[row.bookId] = 0f
            raw > 1f -> fractions[row.bookId] = (raw / 100f).coerceAtMost(1f)
            else -> {
                val key = "$scope|${row.bookId}|${row.lastReadTime}|$raw"
                val cached = resolved[key]
                if (cached != null) fractions[row.bookId] = cached else ambiguous += row to key
            }
        }
    }
    val semaphore = Semaphore(MAX_CONCURRENT_PROGRESS_FETCHES)
    ambiguous.distinctBy { it.second }.map { (row, key) ->
        async {
            val body = semaphore.withPermit { runSuspendCatching { fetchProgress(row.bookId) }.getOrNull() }
            val fraction = body?.let { grimmoryReadProgressFraction(it.readProgress, it.koreaderProgress != null) ?: 0f }
            fraction?.let { resolved[key] = it }
            row.bookId to (fraction ?: 0f)
        }
    }.awaitAll().forEach { (bookId, fraction) -> fractions[bookId] = fraction }
    fractions
}
