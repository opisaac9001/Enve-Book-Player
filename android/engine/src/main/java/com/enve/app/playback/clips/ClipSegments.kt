package com.enve.app.playback.clips

internal data class ClipSourceTrack(val uri: String, val durationMs: Long)

internal data class ClipSegment(val uri: String, val startMs: Long, val endMs: Long) {
    val durationMs: Long get() = endMs - startMs
}

internal fun clipSegments(tracks: List<ClipSourceTrack>, startMs: Long, endMs: Long): List<ClipSegment> {
    var offset = 0L
    return tracks.mapNotNull { track ->
        val trackStart = offset
        offset += track.durationMs
        val overlapStart = maxOf(trackStart, startMs)
        val overlapEnd = minOf(offset, endMs)
        if (overlapEnd > overlapStart) ClipSegment(track.uri, overlapStart - trackStart, overlapEnd - trackStart) else null
    }
}
