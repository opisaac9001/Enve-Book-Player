package com.enve.core.reader

import com.enve.core.data.model.BookSource
import java.io.File

data class ReaderNarrationKey(
    val source: BookSource,
    val connectionId: String?,
    val bookId: String,
)

interface ReaderNarrationSource {
    fun existingReaderAsset(key: ReaderNarrationKey): File?

    suspend fun overlayTimeline(key: ReaderNarrationKey): MediaOverlayTimeline?

    fun narrationTime(key: ReaderNarrationKey): Double?
}
