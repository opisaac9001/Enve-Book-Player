package com.enve.app.playback

import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import kotlin.math.abs

internal data class PlaybackHandoff(
    val mediaItems: List<MediaItem>,
    val currentMediaItemIndex: Int,
    val currentPositionMs: Long,
    val playWhenReady: Boolean,
    val repeatMode: Int,
    val shuffleModeEnabled: Boolean,
    val playbackParameters: PlaybackParameters,
) {
    fun applyTo(player: Player) {
        player.playWhenReady = playWhenReady
        player.repeatMode = repeatMode
        player.shuffleModeEnabled = shuffleModeEnabled
        if (mediaItems.isEmpty()) {
            player.clearMediaItems()
            return
        }
        player.setMediaItems(
            mediaItems,
            currentMediaItemIndex.coerceIn(0, mediaItems.lastIndex),
            currentPositionMs.coerceAtLeast(0L),
        )
        player.playbackParameters = playbackParameters
        player.prepare()
    }

    fun isEstablishedOn(
        player: Player,
        confirmedPositionMs: Long = player.currentPosition,
        confirmedPlayWhenReady: Boolean = player.playWhenReady,
    ): Boolean {
        if (!hasExpectedCurrentItemOn(player) || !hasExpectedQueueOn(player)) return false
        if (confirmedPlayWhenReady != playWhenReady) return false
        return isPositionEstablished(confirmedPositionMs)
    }

    fun hasExpectedCurrentItemOn(player: Player): Boolean {
        if (mediaItems.isEmpty() || player.playbackState != Player.STATE_READY) return false
        val expectedIndex = currentMediaItemIndex.coerceIn(0, mediaItems.lastIndex)
        if (player.currentMediaItemIndex != expectedIndex) return false
        val expectedMediaId = mediaItems[expectedIndex].mediaId
        if (expectedMediaId.isNotBlank() && player.currentMediaItem?.mediaId != expectedMediaId) return false
        return true
    }

    fun hasExpectedQueueOn(player: Player): Boolean {
        if (player.mediaItemCount != mediaItems.size) return false
        return mediaItems.indices.all { index ->
            val expectedMediaId = mediaItems[index].mediaId
            expectedMediaId.isBlank() || player.getMediaItemAt(index).mediaId == expectedMediaId
        }
    }

    fun isPositionEstablishedOn(player: Player): Boolean {
        return isPositionEstablished(player.currentPosition)
    }

    fun isPositionEstablished(positionMs: Long): Boolean {
        val positionToleranceMs = if (playWhenReady) {
            PLAYING_POSITION_CONFIRMATION_TOLERANCE_MS
        } else {
            PAUSED_POSITION_CONFIRMATION_TOLERANCE_MS
        }
        return abs(positionMs.coerceAtLeast(0L) - currentPositionMs.coerceAtLeast(0L)) <=
            positionToleranceMs
    }

    companion object {
        fun capture(player: Player): PlaybackHandoff {
            val items = (0 until player.mediaItemCount).map(player::getMediaItemAt)
            return PlaybackHandoff(
                mediaItems = items,
                currentMediaItemIndex = player.currentMediaItemIndex,
                currentPositionMs = player.currentPosition,
                playWhenReady = player.playWhenReady,
                repeatMode = player.repeatMode,
                shuffleModeEnabled = player.shuffleModeEnabled,
                playbackParameters = player.playbackParameters,
            )
        }

        private const val PLAYING_POSITION_CONFIRMATION_TOLERANCE_MS = 5_000L
        private const val PAUSED_POSITION_CONFIRMATION_TOLERANCE_MS = 2_000L
    }
}
