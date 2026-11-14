package com.enve.core.data.model

import kotlinx.serialization.Serializable

@Serializable
enum class ComicSection(val title: String) {
    ISSUES("Issues"),
    VOLUMES("Volumes"),
    SPECIALS("Specials"),
}

@Serializable
data class ComicMetadata(
    val seriesId: String,
    val section: ComicSection = ComicSection.ISSUES,
    val volumeId: String? = null,
    val volumeTitle: String? = null,
    val volumeOrder: Double? = null,
    val issueLabel: String? = null,
    val issueOrder: Double? = null,
)

private val comicFileTypes = setOf("CBZ", "CBR", "CBX")

val Book.isComic: Boolean
    get() = mediaType == AppMediaType.EBOOK &&
        (comic != null || primaryFileType?.uppercase() in comicFileTypes)
