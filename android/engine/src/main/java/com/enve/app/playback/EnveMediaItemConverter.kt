package com.enve.app.playback

import android.os.Bundle
import androidx.media3.cast.DefaultMediaItemConverter
import androidx.media3.cast.MediaItemConverter
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import com.google.android.gms.cast.MediaQueueItem
import org.json.JSONObject

@UnstableApi
class EnveMediaItemConverter(
    private val delegate: MediaItemConverter = DefaultMediaItemConverter(),
) : MediaItemConverter {

    override fun toMediaItem(mediaQueueItem: MediaQueueItem): MediaItem {
        val item = delegate.toMediaItem(mediaQueueItem)
        val extras = mediaQueueItem.media?.customData?.optJSONObject(CUSTOM_KEY) ?: return item

        val builder = item.buildUpon()
        val durationMs = extras.optLong(KEY_DURATION_MS, -1L)
        if (durationMs > 0L) {
            builder.setMediaMetadata(
                item.mediaMetadata.buildUpon().setDurationMs(durationMs).build(),
            )
        }
        extras.optString(KEY_ORIGINAL_URI).takeIf { it.isNotEmpty() }?.let { original ->
            val requestExtras = Bundle(item.requestMetadata.extras ?: Bundle.EMPTY).apply {
                putString(CAST_ORIGINAL_URI_EXTRA, original)
            }
            builder.setRequestMetadata(
                item.requestMetadata.buildUpon().setExtras(requestExtras).build(),
            )
        }
        return builder.build()
    }

    override fun toMediaQueueItem(mediaItem: MediaItem): MediaQueueItem {
        val queueItem = delegate.toMediaQueueItem(mediaItem)
        val payload = JSONObject().apply {
            mediaItem.mediaMetadata.durationMs?.let { put(KEY_DURATION_MS, it) }
            mediaItem.requestMetadata.extras?.getString(CAST_ORIGINAL_URI_EXTRA)
                ?.let { put(KEY_ORIGINAL_URI, it) }
        }
        if (payload.length() == 0) return queueItem

        val media = queueItem.media ?: return queueItem
        val customData = media.customData ?: JSONObject()
        customData.put(CUSTOM_KEY, payload)
        media.writer.setCustomData(customData)
        return queueItem
    }

    private companion object {
        const val CUSTOM_KEY = "enve"
        const val KEY_DURATION_MS = "durationMs"
        const val KEY_ORIGINAL_URI = "originalUri"
    }
}
