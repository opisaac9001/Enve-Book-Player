package com.enve.app.data.repository

import com.enve.app.data.remote.dto.MediaBrowserItemDto
import com.enve.app.data.remote.dto.MediaBrowserUserDataDto
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.util.FINISHED_PROGRESS_THRESHOLD

private const val TICKS_PER_SECOND = 10_000_000L
private const val TICKS_PER_MILLISECOND = 10_000L

internal fun MediaBrowserItemDto.toBookLibraryOrNull(): Library? {
    val collection = collectionType?.lowercase()
    if (collection != "books" && collection != "audiobooks") return null
    return Library(id = id, name = name ?: return null, bookCount = childCount ?: 0)
}

internal fun MediaBrowserItemDto.toJellyfinBook(serverUrl: String, libraryId: String): Book? {
    val title = name ?: return null
    val base = serverUrl.trimEnd('/')
    val primaryTag = imageTags["Primary"]
    val progress = userData.playedFraction()
    return Book(
        id = id,
        title = title,
        author = personNamed("Author") ?: albumArtist?.takeIf { it.isNotBlank() },
        narrator = people.filter { it.type == "Composer" }.map { it.name }.joinedNames(),
        description = overview,
        coverUrl = if (primaryTag != null) "$base/Items/$id/Images/Primary?tag=$primaryTag" else "$base/Items/$id/Images/Primary",
        duration = durationSeconds,
        currentTime = positionSeconds,
        readProgress = progress,
        source = BookSource.JELLYFIN,
        mediaType = bookMediaType,
        libraryId = libraryId,
        isFinished = progress >= FINISHED_PROGRESS_THRESHOLD,
    )
}

internal fun MediaBrowserItemDto.toEmbyBook(serverUrl: String, libraryId: String): Book? {
    val title = name ?: return null
    val ownTag = imageTags["Primary"]
    val imageReference = when {
        ownTag != null -> id to ownTag
        primaryImageItemId != null && primaryImageTag != null -> primaryImageItemId to primaryImageTag
        parentPrimaryImageItemId != null && parentPrimaryImageTag != null -> parentPrimaryImageItemId to parentPrimaryImageTag
        albumId != null && albumPrimaryImageTag != null -> albumId to albumPrimaryImageTag
        else -> null
    }
    val progress = userData.playedFraction()
    return Book(
        id = id,
        title = title,
        author = personNamed("Author") ?: albumArtist?.takeIf { it.isNotBlank() },
        narrator = composers.map { it.name }.joinedNames(),
        description = overview,
        coverUrl = imageReference?.let { (coverItemId, tag) ->
            "${serverUrl.trimEnd('/')}/Items/$coverItemId/Images/Primary?tag=$tag"
        },
        duration = durationSeconds,
        currentTime = positionSeconds,
        readProgress = progress,
        source = BookSource.EMBY,
        mediaType = bookMediaType,
        libraryId = libraryId,
        isFinished = progress >= FINISHED_PROGRESS_THRESHOLD,
    )
}

internal val MediaBrowserItemDto.durationMs: Long
    get() = (runTimeTicks ?: 0L) / TICKS_PER_MILLISECOND

private val MediaBrowserItemDto.durationSeconds: Long
    get() = (runTimeTicks ?: 0L) / TICKS_PER_SECOND

private val MediaBrowserItemDto.positionSeconds: Long
    get() = (userData?.playbackPositionTicks ?: 0L) / TICKS_PER_SECOND

private val MediaBrowserItemDto.bookMediaType: AppMediaType
    get() = if (type == "Book") AppMediaType.EBOOK else AppMediaType.AUDIOBOOK

private fun MediaBrowserItemDto.personNamed(role: String): String? =
    people.firstOrNull { it.type == role }?.name

private fun List<String>.joinedNames(): String? =
    filter { it.isNotBlank() }.distinct().joinToString(", ").ifEmpty { null }

private fun MediaBrowserUserDataDto?.playedFraction(): Float =
    ((this?.playedPercentage ?: 0.0) / 100.0).toFloat().coerceIn(0f, 1f)
