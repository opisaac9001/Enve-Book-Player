package com.enve.audiobookshelf

import android.util.Log
import com.enve.audiobookshelf.api.AudiobookshelfApi
import com.enve.audiobookshelf.dto.AbsMediaProgressDto
import com.enve.core.data.local.SyncedItemAudioTimeStore
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.reader.EpubCfi
import com.enve.core.reader.MediaOverlayTimeline
import com.enve.core.reader.ReaderNarrationKey
import com.enve.core.reader.ReaderNarrationSource
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Singleton
class AbsEbookPositionResolver @Inject constructor(
    private val api: AudiobookshelfApi,
    private val narration: ReaderNarrationSource,
    private val syncedAudioTimes: SyncedItemAudioTimeStore,
    private val serverSync: com.enve.core.data.local.ProfileServerSyncStore,
) {
    private val itemAudioDurations = ConcurrentHashMap<ReaderNarrationKey, Double>()

    suspend fun pushEbookProgress(bookId: String, percentage: Float, locator: String?) {
        val syncStartedAt = System.currentTimeMillis()
        if (!serverSync.isEnabled) return
        val key = ReaderNarrationKey(BookSource.AUDIOBOOKSHELF, ConnectionScope.getConnectionId(), bookId)
        val readiumLocator = locator?.let(::absReadiumLocator)
        val ebookLocation = readiumLocator?.let { json ->
            narration.existingReaderAsset(key)?.let { epub ->
                epubWork("EPUB CFI upload conversion failed") { EpubCfi.providerCfi(json, epub) }
                    ?: run {
                        Log.i(TAG, "ABS ebook position did not round-trip as a CFI; sending progress only")
                        null
                    }
            }
        }
        val itemAudioDuration = itemAudioDuration(key)
        val audioPosition = itemAudioDuration?.takeIf { it > 0.0 }?.let { duration ->
            readiumLocator?.let { narrationAudioPosition(key, it, duration) }
        }
        val body = absEbookProgressBody(
            progress = percentage.coerceIn(0f, 1f),
            ebookLocation = ebookLocation,
            itemHasAudio = itemAudioDuration != 0.0,
            audioPosition = audioPosition,
        )
        if (!serverSync.accepts(syncStartedAt)) return
        val response = api.updateEbookProgress(libraryItemId = bookId, body = body)
        if (!response.isSuccessful) error("Audiobookshelf ebook progress sync failed: HTTP ${response.code()}")
        audioPosition?.let { syncedAudioTimes.record(key, it.currentTime) }
    }

    suspend fun ebookSnapshot(book: Book, record: AbsMediaProgressDto): SyncSnapshot? {
        val syncStartedAt = System.currentTimeMillis()
        if (!serverSync.isEnabled) return null
        val ebookFraction = when {
            !(book.hasAudio && book.hasEbook) -> record.ebookProgress ?: record.progress
            absHasEbookPosition(record) -> record.ebookProgress
            else -> null
        }
        var percentage = ebookFraction?.coerceIn(0f, 1f) ?: 0f
        val serverLocation = absServerEbookLocation(record.ebookLocation)
        var locator = (serverLocation as? AbsServerEbookLocation.ReadiumLocatorJson)?.json
        var epubCfi = (serverLocation as? AbsServerEbookLocation.Cfi)?.cfi
        val cfi = epubCfi
        val key = ReaderNarrationKey(book.source, book.connectionId, book.id)
        val epub = narration.existingReaderAsset(key)
        if (cfi != null && epub != null) {
            epubWork("EPUB CFI resolution failed") { EpubCfi.readiumLocatorJson(cfi, percentage.toDouble(), epub) }?.let {
                locator = it
                epubCfi = null
            }
        }
        narratedPositionFromItemAudio(record, locator, key)?.let { (narratedLocator, progression) ->
            locator = narratedLocator
            epubCfi = null
            percentage = progression.toFloat()
        }
        if (percentage <= 0f) return null
        if (!serverSync.accepts(syncStartedAt)) return null
        return SyncSnapshot(
            percentage = percentage,
            locatorJson = locator,
            epubCfi = epubCfi,
            source = "Audiobookshelf",
            updatedAt = record.lastUpdate?.takeIf { it > 0L },
            finished = record.resolvedIsFinished,
        )
    }

    private suspend fun narrationAudioPosition(
        key: ReaderNarrationKey,
        locator: String,
        itemAudioDuration: Double,
    ): AbsAudioPosition? {
        val narrationTime = narration.narrationTime(key) ?: return null
        val timeline = narration.overlayTimeline(key) ?: return null
        val resolved = timeline.resolveEpub3Locator(locator)
            ?.takeIf { it.source == MediaOverlayTimeline.Source.FRAGMENT }
            ?: return null
        return absItemAudioPosition(
            narrationTime = narrationTime,
            clip = timeline.clipTimings[resolved.clipIndex],
            overlayDuration = timeline.totalAudioDuration,
            itemAudioDuration = itemAudioDuration,
        )
    }

    private suspend fun narratedPositionFromItemAudio(
        record: AbsMediaProgressDto,
        serverLocator: String?,
        key: ReaderNarrationKey,
    ): Pair<String, Double>? {
        val audioTime = record.currentTime?.takeIf { it > 0.0 } ?: return null
        val itemDuration = itemAudioDuration(key)?.takeIf { it > 0.0 } ?: return null
        val timeline = narration.overlayTimeline(key) ?: return null
        if (!MediaOverlayTimeline.narrationMatchesAudio(timeline.totalAudioDuration, itemDuration)) return null
        val lastSyncedAudioTime = syncedAudioTimes.lastSyncedTime(key)
        syncedAudioTimes.record(key, audioTime)
        return absNarratedLocator(
            itemAudioTime = audioTime,
            itemAudioDuration = itemDuration,
            timeline = timeline,
            serverLocator = serverLocator,
            lastSyncedAudioTime = lastSyncedAudioTime,
        )
    }

    private suspend fun itemAudioDuration(key: ReaderNarrationKey): Double? {
        itemAudioDurations[key]?.let { return it }
        val response = try {
            api.getExpandedItem(key.bookId)
        } catch (e: IOException) {
            Log.w(TAG, "ABS item lookup failed: ${e.message}")
            return null
        }
        if (!response.isSuccessful) return null
        val duration = response.body()?.media?.duration?.takeIf { it > 0.0 } ?: 0.0
        itemAudioDurations[key] = duration
        return duration
    }

    private suspend fun <T> epubWork(failure: String, block: () -> T?): T? = withContext(Dispatchers.IO) {
        try {
            block()
        } catch (e: IOException) {
            Log.w(TAG, "$failure: ${e.message}")
            null
        }
    }

    private companion object {
        const val TAG = "AbsEbookPosition"
    }
}
