package com.enve.app.data.offline

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import dagger.MapKey

data class ResolvedTrack(
    val index: Int,
    val title: String?,
    val durationMs: Long,
    val url: String,
    val httpHeaders: Map<String, String> = emptyMap(),
    val sizeBytes: Long = 0L,
    val assetId: String? = null,
)

interface AudiobookTrackResolver {
    suspend fun resolveTracks(book: Book): Result<List<ResolvedTrack>>
}

@MapKey
@Retention(AnnotationRetention.RUNTIME)
annotation class AudiobookTrackResolverKey(val value: BookSource)
