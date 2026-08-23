package com.enve.app.data.offline

import android.util.Log
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.komga.KomgaRepository
import com.enve.app.data.repository.SeriesPolicyStore
import com.enve.app.data.repository.seriesKeyFor
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class BookCompletionHandler @Inject constructor(
    private val prefs: PreferencesManager,
    private val seriesPolicies: SeriesPolicyStore,
    private val offlineDownloadManager: OfflineDownloadManager,
    private val comicOfflineService: ComicOfflineService,
    private val komgaRepository: KomgaRepository,
) {
    suspend fun onBookFinished(book: Book) {
        val seriesKey = seriesKeyFor(book.connectionId, book.seriesName)
        val policy = seriesKey?.let { seriesPolicies.policyFor(it).first() }

        val shouldDelete = policy?.autoDelete ?: prefs.autoDeleteFinishedBooks.first()
        if (shouldDelete) {
            offlineDownloadManager.removeDownload(book.id)
            comicOfflineService.removeDownload(book.id)
        }

        val autoDownload = policy?.autoDownloadNext ?: false
        if (!autoDownload) return
        if (book.source != BookSource.KOMGA || book.seriesName.isNullOrBlank()) return

        runCatching { triggerAutoDownloadNext(book, policy.downloadAheadCount ?: prefs.seriesPreDownloadCount.first()) }
            .onFailure { Log.w("BookCompletionHandler", "Auto-download next failed for ${book.title}", it) }
    }

    private suspend fun triggerAutoDownloadNext(book: Book, count: Int) {
        val seriesId = komgaRepository.getSeriesIdForBook(book.id) ?: return
        val seriesBooks = komgaRepository.getSeriesBooks(seriesId).getOrNull().orEmpty()
        val currentIdx = seriesBooks.indexOfFirst { it.id == book.id }
        if (currentIdx < 0) return

        val next = seriesBooks.drop(currentIdx + 1).take(count)
            .filterNot { comicOfflineService.isDownloaded(it.id) }
        if (next.isNotEmpty()) {
            comicOfflineService.startDownloadAll(next)
            Log.d("BookCompletionHandler", "Auto-queued ${next.size} books after finishing ${book.title}")
        }
    }
}
