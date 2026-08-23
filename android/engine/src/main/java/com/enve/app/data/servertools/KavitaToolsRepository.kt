package com.enve.app.data.servertools

import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.KavitaAnnotationDto
import kotlinx.coroutines.CancellationException
import javax.inject.Inject
import javax.inject.Singleton
import retrofit2.Response

data class KavitaReadingStats(
    val booksRead: Int,
    val comicsRead: Int,
    val pagesRead: Long,
    val wordsRead: Long,
    val authorsRead: Int,
    val hoursSpentReading: Long,
    val averageHoursPerWeek: Double,
    val lastActiveUtc: String?,
)

data class KavitaAnnotation(
    val id: Int,
    val seriesName: String?,
    val chapterTitle: String?,
    val text: String,
    val note: String?,
    val createdUtc: String?,
)

@Singleton
class KavitaToolsRepository @Inject constructor(
    private val api: GrimmoryApi,
) {
    suspend fun stats(): Result<KavitaReadingStats?> = runCatching {
        val userId = currentUserId() ?: return@runCatching null
        val bar = optional { api.kavitaUserStatBar(userId) }
        val read = optional { api.kavitaUserReadStatistics(userId) }
        if (bar == null && read == null) return@runCatching null
        KavitaReadingStats(
            booksRead = bar?.booksRead ?: 0,
            comicsRead = bar?.comicsRead ?: 0,
            pagesRead = read?.totalPagesRead ?: bar?.pagesRead?.toLong() ?: 0L,
            wordsRead = read?.totalWordsRead ?: bar?.wordsRead?.toLong() ?: 0L,
            authorsRead = bar?.authorsRead ?: 0,
            hoursSpentReading = read?.timeSpentReading ?: 0L,
            averageHoursPerWeek = read?.avgHoursPerWeekSpentReading ?: 0.0,
            lastActiveUtc = read?.lastActiveUtc,
        )
    }

    suspend fun annotations(limit: Int): Result<List<KavitaAnnotation>?> = runCatching {
        val seriesResponse = api.kavitaSeriesWithAnnotations()
        if (seriesResponse.code() == 404) return@runCatching null
        if (!seriesResponse.isSuccessful) error("Kavita annotated series failed: HTTP ${seriesResponse.code()}")
        val series = seriesResponse.body().orEmpty().filter { it.id > 0 }
        buildList {
            for (entry in series.take(ANNOTATED_SERIES)) {
                if (size >= limit) break
                val annotations = optional { api.kavitaAnnotationsForSeries(entry.id) }.orEmpty()
                annotations.forEach { add(it.toAnnotation(entry.name)) }
            }
        }
            .filter { it.text.isNotBlank() }
            .sortedByDescending { it.createdUtc.orEmpty() }
            .take(limit)
    }

    private suspend fun currentUserId(): Int? {
        val response = optional { api.kavitaAccount() } ?: return null
        return response.id.takeIf { it > 0 }
    }

    private fun KavitaAnnotationDto.toAnnotation(seriesFallback: String?): KavitaAnnotation = KavitaAnnotation(
        id = id,
        seriesName = seriesName?.takeIf { it.isNotBlank() } ?: seriesFallback?.takeIf { it.isNotBlank() },
        chapterTitle = chapterTitle?.takeIf { it.isNotBlank() },
        text = selectedText?.takeIf { it.isNotBlank() } ?: commentPlainText.orEmpty(),
        note = commentPlainText?.takeIf { it.isNotBlank() && it != selectedText },
        createdUtc = createdUtc,
    )

    private suspend fun <T> optional(request: suspend () -> Response<T>): T? = try {
        val response = request()
        if (response.isSuccessful) response.body() else null
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    private companion object {
        const val ANNOTATED_SERIES = 8
    }
}
