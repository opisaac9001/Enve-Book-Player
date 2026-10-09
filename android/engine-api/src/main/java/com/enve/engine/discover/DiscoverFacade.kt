package com.enve.engine.discover

import com.enve.core.data.model.Book

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
    val infoUrl: String?,
    val libraryMatch: Book?,
)

data class DiscoverSection(
    val id: String,
    val title: String,
    val subtitle: String,
    val books: List<DiscoverBook>,
)

interface DiscoverFacade {
    suspend fun load(force: Boolean = false): List<DiscoverSection>
}
