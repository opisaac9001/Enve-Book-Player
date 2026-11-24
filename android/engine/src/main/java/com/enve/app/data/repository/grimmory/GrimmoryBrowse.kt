package com.enve.app.data.repository.grimmory

internal val GRIMMORY_READING_STATUSES = listOf("READING", "RE_READING")

internal val GRIMMORY_EBOOK_FILE_TYPES = listOf("EPUB", "PDF", "CBX", "FB2", "MOBI", "AZW3")

internal fun grimmoryFacet(key: String, value: Any): String = "$key:$value"

internal fun grimmoryBrowseSort(sort: String, dir: String): String {
    val key = when (sort) {
        "title", "seriesName", "seriesNumber", "narrator", "publishedDate", "publisher", "language",
        "pageCount", "goodreadsRating", "lastReadTime", "readStatus", "dateFinished", "personalRating" -> sort
        "authors", "author", "authorName" -> "authorName"
        "series" -> "seriesName"
        "readProgress" -> "readingProgress"
        else -> "addedOn"
    }
    return if (dir.equals("asc", ignoreCase = true)) key else "-$key"
}
