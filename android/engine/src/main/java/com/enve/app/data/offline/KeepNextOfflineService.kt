package com.enve.app.data.offline

import android.util.Log
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.KeepNextOfflineSettings
import com.enve.core.data.local.KeepNextOfflineStore
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.KeepNextOfflinePolicy
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class KeepNextOfflineService @Inject constructor(
    private val store: KeepNextOfflineStore,
    private val preferences: PreferencesManager,
    private val bookCache: BookCacheDao,
    private val downloads: OfflineDownloadManager,
) {
    val settings: Flow<KeepNextOfflineSettings> = store.settings

    private val reconcileMutex = Mutex()

    suspend fun reconcile(current: Book) {
        reconcileMutex.withLock {
            val preference = settings.first()
            if (!preference.enabled || current.mediaType != AppMediaType.AUDIOBOOK) return@withLock
            if (!downloads.isDownloaded(current.id)) return@withLock

            val series = current.seriesName?.trim()?.takeIf(String::isNotEmpty) ?: return@withLock
            val candidates = bookCache.audiobooksInSeries(
                seriesName = series,
                source = current.source.name,
                connectionId = current.connectionId,
                libraryId = current.libraryId,
            ).map { it.toBook() }
            val missing = KeepNextOfflinePolicy.downloadsNeeded(
                candidates = KeepNextOfflinePolicy.seriesCandidates(current, candidates),
                targetCount = preference.count,
                isKeptOffline = ::isKeptOffline,
            )
            if (missing.isEmpty()) return@withLock

            val allowCellular = preferences.downloadOnCellular.first()
            missing.forEach { downloads.startAudiobookDownload(it, allowCellular) }
            Log.i(TAG, "Queued ${missing.size} upcoming book(s) after ${current.title}")
        }
    }

    private fun isKeptOffline(book: Book): Boolean {
        val status = downloads.progressByBookId.value[book.id]?.status
        return downloads.isDownloaded(book.id) ||
            status == OfflineDownloadStatus.QUEUED ||
            status == OfflineDownloadStatus.DOWNLOADING
    }

    private companion object {
        const val TAG = "KeepNextOffline"
    }
}
