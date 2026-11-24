package com.enve.silo

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.provider.RemoteCatalogFilterOptions
import com.enve.core.data.provider.RemoteCatalogRequest
import com.enve.core.data.provider.RemoteCatalogSort
import com.enve.silo.api.SiloApi
import com.enve.silo.dto.SiloCatalogItemDto
import com.enve.silo.dto.SiloCatalogQueryGroup
import com.enve.silo.dto.SiloCatalogQueryRequest
import com.enve.silo.dto.SiloCatalogQueryRule
import com.enve.silo.dto.SiloCollection
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

internal suspend fun SiloApi.remoteCatalogPage(
    profileId: String,
    libraryId: String,
    request: RemoteCatalogRequest,
    cursor: String?,
    limit: Int,
): SiloCollection<SiloCatalogItemDto> {
    val type = request.mediaType?.siloCatalogType()
    val search = request.search.trim().takeIf(String::isNotEmpty)
    val recent = request.sort == RemoteCatalogSort.RECENTLY_ADDED
    val response = if (request.genres.isEmpty() && request.languages.isEmpty()) {
        catalog(profileId, libraryId, if (recent) "-added_at" else "title", cursor, limit.coerceIn(1, 200), search = search, type = type)
    } else {
        val groups = listOf("genre" to request.genres, "original_language" to request.languages)
            .filter { it.second.isNotEmpty() }
            .map { (field, values) -> SiloCatalogQueryGroup(values.sorted().map { SiloCatalogQueryRule(field, it) }) }
        catalogQuery(profileId, SiloCatalogQueryRequest(
            libraryId = libraryId,
            type = type,
            q = search,
            sort = if (recent) "added_at" else "title",
            order = if (recent) "desc" else "asc",
            limit = limit.coerceIn(1, 100),
            cursor = cursor,
            groups = groups,
        ))
    }
    val result = response.siloBody("Silo search failed")
    require(result.items.all { it.contentId.isNotBlank() && it.title.isNotBlank() }) { "Silo returned an incomplete catalog card" }
    val next = result.page?.nextCursor
    require(next == null || next.isNotBlank() && next != cursor) { "Silo returned an invalid catalog cursor" }
    require(result.page?.hasMore != true || next != null) { "Silo omitted the next catalog cursor" }
    return result
}

internal suspend fun SiloApi.remoteCatalogFilterOptions(
    profileId: String,
    libraryId: String,
    mediaType: AppMediaType?,
    search: String,
): RemoteCatalogFilterOptions = coroutineScope {
    val capabilities = catalogSearchCapabilities(profileId)
    if (capabilities.code() == 404 || capabilities.siloBody("Silo filter capabilities failed").facetValueSearch.not()) {
        throw UnsupportedOperationException("Update this Silo server to search genre and language options.")
    }
    val type = mediaType?.siloCatalogType()
    val query = search.trim().takeIf(String::isNotEmpty)
    val genres = async { catalogFilterSearch(profileId, libraryId, type, query, "genre").siloBody("Silo genre search failed") }
    val languages = async { catalogFilterSearch(profileId, libraryId, type, query, "original_language").siloBody("Silo language search failed") }
    val genreValues = genres.await()
    val languageValues = languages.await()
    RemoteCatalogFilterOptions(
        genreValues.values.map { it.value },
        languageValues.values.map { it.value },
        genreValues.valuesHasMore || languageValues.valuesHasMore,
    )
}

private fun AppMediaType.siloCatalogType(): String = when (this) {
    AppMediaType.AUDIOBOOK -> "audiobook"
    AppMediaType.EBOOK -> "ebook"
    else -> error("Silo catalog browsing supports audiobooks and ebooks")
}
