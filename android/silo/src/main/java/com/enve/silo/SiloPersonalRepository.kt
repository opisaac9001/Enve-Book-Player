package com.enve.silo

import com.enve.core.data.util.runSuspendCatching
import com.enve.silo.api.SiloApi
import com.enve.silo.dto.SiloCollection
import com.enve.silo.dto.SiloHistoryCardDto
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.roundToLong

data class SiloHistoryItem(
    val contentId: String,
    val title: String,
    val seriesTitle: String?,
    val type: String,
    val runtimeSeconds: Long,
)

data class SiloSimilarItem(
    val contentId: String,
)

internal fun SiloHistoryCardDto.toHistoryItem() = SiloHistoryItem(
    contentId = contentId,
    title = title.takeIf { it.isNotBlank() } ?: "Untitled",
    seriesTitle = seriesTitle?.takeIf { it.isNotBlank() },
    type = type,
    runtimeSeconds = (watch?.durationSeconds?.takeIf { it > 0.0 }?.roundToLong() ?: (runtimeMinutes * 60L))
        .coerceAtLeast(0L),
)

@Singleton
class SiloPersonalRepository @Inject constructor(
    private val api: SiloApi,
    private val repository: SiloRepository,
) {
    suspend fun history(limit: Int): Result<List<SiloHistoryItem>?> = runSuspendCatching {
        val profileId = repository.ensureProfile()
        val count = limit.coerceIn(1, 200)
        var missing = false
        val cards = siloFillPage(SiloPageStart(null), count) { cursor ->
            val response = api.history(profileId, cursor, count)
            if (response.code() == 404) {
                missing = true
                SiloCollection()
            } else {
                response.siloBody("Silo history failed")
            }
        }.items
        if (missing) null else cards.map { it.toHistoryItem() }
    }

    suspend fun similar(contentId: String, limit: Int): Result<List<SiloSimilarItem>?> = runSuspendCatching {
        val response = api.similarItems(repository.ensureProfile(), contentId, limit.coerceIn(1, 50))
        if (response.code() == 404) return@runSuspendCatching null
        response.siloBody("Silo similar items failed").items
            .filter { it.contentId.isNotBlank() && it.contentId != contentId }
            .map { SiloSimilarItem(it.contentId) }
    }
}
