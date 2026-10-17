package com.enve.plex

import com.enve.plex.api.PlexApi
import com.enve.plex.dto.PlexMedia
import com.enve.plex.dto.PlexMetadata
import com.enve.plex.dto.PlexPart

internal data class PlexRendition(val media: PlexMedia, val part: PlexPart) {
    val format: String?
        get() = media.container ?: media.audioCodec ?: part.container ?: part.file?.substringAfterLast('.', "")
}

internal data class PlexPlayableTrack(
    val metadata: PlexMetadata,
    val rendition: PlexRendition,
    val startMs: Long,
    val durationMs: Long,
)

internal data class PlexPlayableTracks(val isAlbum: Boolean, val tracks: List<PlexPlayableTrack>)

private val media3Formats = setOf(
    "mp3", "mp4", "m4a", "m4b", "aac", "flac", "wav", "wave", "ogg", "oga", "opus", "vorbis", "webm", "mka", "amr",
)

internal val plexTrackOrder = compareBy<PlexMetadata>(
    { it.parentIndex ?: 0 },
    { it.index ?: Int.MAX_VALUE },
    { it.ratingKey },
)

internal fun PlexMetadata.playableRendition(): PlexRendition? {
    val renditions = media.mapNotNull { media ->
        media.part.firstOrNull { it.key.isNotEmpty() }?.let { PlexRendition(media, it) }
    }
    return renditions.firstOrNull { it.format?.lowercase() in media3Formats } ?: renditions.firstOrNull()
}

internal fun PlexRendition.durationMs(metadata: PlexMetadata): Long =
    media.duration ?: part.duration ?: metadata.duration ?: 0L

internal suspend fun PlexApi.playableTracks(bookId: String): PlexPlayableTracks? {
    val rootResp = getMetadata(bookId)
    if (!rootResp.isSuccessful) error("Plex metadata HTTP ${rootResp.code()}")
    val root = rootResp.body()?.mediaContainer?.metadata?.firstOrNull() ?: return null
    val isAlbum = root.type == "album" || root.media.isEmpty()
    val items = if (isAlbum) {
        val childrenResp = getMetadataChildren(bookId)
        if (!childrenResp.isSuccessful) error("Plex children HTTP ${childrenResp.code()}")
        childrenResp.body()?.mediaContainer?.metadata.orEmpty().sortedWith(plexTrackOrder)
    } else {
        listOf(root)
    }
    var start = 0L
    val tracks = items.map { item ->
        val rendition = item.playableRendition() ?: error("Plex track ${item.ratingKey} has no playable part")
        val duration = rendition.durationMs(item)
        PlexPlayableTrack(item, rendition, start, duration).also { start += duration }
    }
    return PlexPlayableTracks(isAlbum, tracks)
}
