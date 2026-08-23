package com.enve.audiobookshelf

import com.enve.audiobookshelf.api.AudiobookshelfApi
import com.enve.audiobookshelf.dto.AbsListeningStatsDto
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.roundToLong

data class AbsListeningStats(
    val totalSeconds: Long,
    val todaySeconds: Long,
    val activeDays: Int,
    val bestDay: String?,
    val bestDaySeconds: Long,
    val busiestWeekday: String?,
)

data class AbsBookmark(
    val libraryItemId: String,
    val title: String,
    val timeSeconds: Long,
    val createdAtMs: Long?,
)

@Singleton
class AudiobookshelfPersonalRepository @Inject constructor(
    private val api: AudiobookshelfApi,
) {
    suspend fun listeningStats(): Result<AbsListeningStats?> = runCatching {
        val response = api.getListeningStats()
        if (response.code() == 404) return@runCatching null
        if (!response.isSuccessful) error("Audiobookshelf listening stats failed: HTTP ${response.code()}")
        response.body()?.toStats()
    }

    suspend fun bookmarks(): Result<List<AbsBookmark>> = runCatching {
        val response = api.getMe()
        if (!response.isSuccessful) error("Audiobookshelf profile failed: HTTP ${response.code()}")
        response.body()?.bookmarks.orEmpty()
            .mapNotNull { bookmark ->
                val itemId = bookmark.libraryItemId?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
                AbsBookmark(
                    libraryItemId = itemId,
                    title = bookmark.title.takeIf { it.isNotBlank() } ?: "Bookmark",
                    timeSeconds = bookmark.time.roundToLong().coerceAtLeast(0L),
                    createdAtMs = bookmark.createdAt?.takeIf { it > 0L },
                )
            }
            .sortedByDescending { it.createdAtMs ?: 0L }
    }

    private fun AbsListeningStatsDto.toStats(): AbsListeningStats {
        val activeDays = days.filterValues { it > 0.0 }
        val best = activeDays.maxByOrNull { it.value }
        return AbsListeningStats(
            totalSeconds = totalTime.roundToLong().coerceAtLeast(0L),
            todaySeconds = today.roundToLong().coerceAtLeast(0L),
            activeDays = activeDays.size,
            bestDay = best?.key,
            bestDaySeconds = best?.value?.roundToLong()?.coerceAtLeast(0L) ?: 0L,
            busiestWeekday = dayOfWeek.filterValues { it > 0.0 }.maxByOrNull { it.value }?.key,
        )
    }
}
