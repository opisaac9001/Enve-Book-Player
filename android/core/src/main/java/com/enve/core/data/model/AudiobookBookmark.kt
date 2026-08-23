package com.enve.core.data.model

import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
data class AudiobookBookmark(
    val id: String = UUID.randomUUID().toString(),
    val bookId: String,
    val position: Long,
    val title: String,
    val note: String? = null,
    val timestamp: Long = System.currentTimeMillis(),
    val locator: String? = null,
    val mediaType: AppMediaType = AppMediaType.AUDIOBOOK,
    val chapterTitle: String? = null,
    val remoteId: Int? = null,
    val isRemotePlaceholder: Boolean = false,
) {
    val formattedTime: String
        get() = when {
            isRemotePlaceholder -> "Synced"
            mediaType == AppMediaType.EBOOK -> "${(position * 100).toInt()}%"
            else -> formatTime(position)
        }

    companion object {
        fun formatTime(seconds: Long): String {
            val safe = seconds.coerceAtLeast(0)
            val hours = safe / 3600
            val minutes = (safe % 3600) / 60
            val remainingSeconds = safe % 60
            return if (hours > 0) {
                "%d:%02d:%02d".format(hours, minutes, remainingSeconds)
            } else {
                "%d:%02d".format(minutes, remainingSeconds)
            }
        }
    }
}
