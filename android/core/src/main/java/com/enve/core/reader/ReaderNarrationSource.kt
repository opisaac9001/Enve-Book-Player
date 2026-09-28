package com.enve.core.reader

import java.io.File

interface ReaderNarrationSource {
    fun existingReaderAsset(bookId: String): File?

    suspend fun overlayTimeline(bookId: String): MediaOverlayTimeline?

    fun narrationTime(bookId: String): Double?
}
