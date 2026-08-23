package com.enve.app.data.discover

data class DiscoverSection(
    val id: DiscoverSectionId,
    val title: String,
    val subtitle: String,
    val books: List<DiscoverBook>,
)

enum class DiscoverSectionId {
    TRENDING,
    BESTSELLERS,
    NEW_RELEASES,
}

data class DiscoverBook(
    val id: String,
    val title: String,
    val author: String?,
    val artworkUrl: String?,
    val description: String?,
    val publishedDate: String?,
    val genre: String?,
    val pageCount: Int?,
    val durationMillis: Long?,
    val previewUrl: String?,
    val infoUrl: String?,
    val collectionId: String?,
) {
    val secureArtworkUrl: String?
        get() = artworkUrl?.toHttpsUrl()

    val displayAuthor: String
        get() = author?.takeIf { it.isNotBlank() } ?: "Unknown author"

    val displayYear: String?
        get() = publishedDate
            ?.take(4)
            ?.takeIf { year -> year.length == 4 && year.all(Char::isDigit) }

    val displayRuntime: String?
        get() = durationMillis
            ?.takeIf { it > 0L }
            ?.let { millis ->
                val totalMinutes = millis / 60_000L
                val hours = totalMinutes / 60L
                val minutes = totalMinutes % 60L
                if (hours > 0L) "${hours}h ${minutes}m" else "${minutes}m"
            }

    val displayMeta: String
        get() = listOfNotNull(displayYear, genre, displayRuntime, pageCount?.let { "$it pages" }).joinToString(" · ")
}

private fun String.toHttpsUrl(): String =
    if (startsWith("http://")) "https://${removePrefix("http://")}" else this
