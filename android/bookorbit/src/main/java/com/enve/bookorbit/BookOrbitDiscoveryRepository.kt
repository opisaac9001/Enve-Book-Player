package com.enve.bookorbit

import com.enve.bookorbit.api.BookOrbitApi
import com.enve.bookorbit.dto.BookOrbitRecommendationDto
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import javax.inject.Inject
import javax.inject.Singleton
import retrofit2.Response

data class BookOrbitRelatedBook(
    val id: Int,
    val title: String,
    val authors: List<String>,
    val coverUrl: String?,
    val seriesIndex: Double?,
    val isAudiobook: Boolean,
)

data class BookOrbitRelatedBooks(
    val recommendations: List<BookOrbitRelatedBook>,
    val seriesBooks: List<BookOrbitRelatedBook>,
    val authorBooks: List<BookOrbitRelatedBook>,
    val supported: Boolean,
) {
    val isEmpty: Boolean
        get() = recommendations.isEmpty() && seriesBooks.isEmpty() && authorBooks.isEmpty()
}

@Singleton
class BookOrbitDiscoveryRepository @Inject constructor(
    private val api: BookOrbitApi,
    private val endpoints: BookOrbitEndpoints,
) {
    suspend fun getRelatedBooks(bookId: String): Result<BookOrbitRelatedBooks> = runCatching {
        val id = bookId.toIntOrNull() ?: error("Invalid BookOrbit book id")
        coroutineScope {
            val recommendations = async { fetch { api.recommendations(id) } }
            val series = async { fetch { api.seriesBooks(id) } }
            val authors = async { fetch { api.authorBooks(id) } }
            val results = listOf(recommendations.await(), series.await(), authors.await())
            BookOrbitRelatedBooks(
                recommendations = results[0].orEmpty(),
                seriesBooks = results[1].orEmpty().filterNot { it.id == id },
                authorBooks = results[2].orEmpty(),
                supported = results.any { it != null },
            )
        }
    }

    private suspend fun fetch(
        request: suspend () -> Response<List<BookOrbitRecommendationDto>>,
    ): List<BookOrbitRelatedBook>? {
        val response = request()
        if (response.code() == 404) return null
        if (!response.isSuccessful) error("BookOrbit related books failed: HTTP ${response.code()}")
        return response.body().orEmpty().map { it.toRelatedBook() }
    }

    private fun BookOrbitRecommendationDto.toRelatedBook(): BookOrbitRelatedBook = BookOrbitRelatedBook(
        id = id,
        title = title?.takeIf { it.isNotBlank() } ?: "Untitled",
        authors = authors.filter { it.isNotBlank() },
        coverUrl = if (hasCover) endpoints.coverUrl(id) else null,
        seriesIndex = seriesIndex,
        isAudiobook = isAudiobook,
    )
}
