package com.enve.silo

import com.enve.silo.api.SiloApi
import javax.inject.Inject
import javax.inject.Singleton

data class SiloHistoryItem(
    val contentId: String,
    val title: String,
    val seriesTitle: String?,
    val type: String,
    val runtimeSeconds: Long,
)

data class SiloSimilarItem(
    val contentId: String,
    val score: Double,
    val reason: String?,
)

@Singleton
class SiloPersonalRepository @Inject constructor(
    private val api: SiloApi,
    private val repository: SiloRepository,
) {
    suspend fun history(limit: Int): Result<List<SiloHistoryItem>?> = runCatching {
        val response = api.history(repository.ensureProfile(), limit.coerceIn(1, 100))
        if (response.code() == 404) return@runCatching null
        if (!response.isSuccessful) error("Silo history failed: HTTP ${response.code()}")
        response.body()?.items.orEmpty().map { entry ->
            SiloHistoryItem(
                contentId = entry.contentId,
                title = entry.title.takeIf { it.isNotBlank() } ?: "Untitled",
                seriesTitle = entry.seriesTitle?.takeIf { it.isNotBlank() },
                type = entry.type,
                runtimeSeconds = entry.runtime.toLong().coerceAtLeast(0L),
            )
        }
    }

    suspend fun similar(contentId: String, limit: Int): Result<List<SiloSimilarItem>?> = runCatching {
        val response = api.similarItems(repository.ensureProfile(), contentId, limit.coerceIn(1, 50))
        if (response.code() == 404) return@runCatching null
        if (!response.isSuccessful) error("Silo similar items failed: HTTP ${response.code()}")
        response.body()?.items.orEmpty()
            .filter { it.mediaItemId.isNotBlank() && it.mediaItemId != contentId }
            .map { SiloSimilarItem(it.mediaItemId, it.score, it.reason.takeIf { r -> r.isNotBlank() }) }
    }
}
