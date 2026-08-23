package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.KeepNextOfflineStore
import com.enve.core.data.local.toBook
import com.enve.core.data.util.NaturalSort
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.app.data.offline.ComicOfflineService
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.offline.OfflineDownloadProgress
import com.enve.app.data.offline.OfflineDownloadStatus
import com.enve.app.data.repository.GrimmoryRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class DownloadsHubState(
    val downloadedBooks: List<Book> = emptyList(),
    val activeDownloads: List<OfflineDownloadProgress> = emptyList(),
    val terminalDownloads: List<OfflineDownloadProgress> = emptyList(),
    val isLoading: Boolean = false,
    val error: String? = null,
    val autoDeleteFinishedBooks: Boolean = false,
    val autoDeleteFailedDownloads: Boolean = true,
    val seriesPreDownloadCount: Int = 5,
    val downloadOnCellular: Boolean = false,
    val keepNextOfflineEnabled: Boolean = false,
    val keepNextOfflineCount: Int = 1,
)

@HiltViewModel
class DownloadsHubViewModel @Inject constructor(
    private val repository: GrimmoryRepository,
    private val offlineDownloadManager: OfflineDownloadManager,
    private val comicOfflineService: ComicOfflineService,
    private val bookCacheDao: BookCacheDao,
    private val prefs: com.enve.core.data.local.PreferencesManager,
    private val keepNextOfflineStore: KeepNextOfflineStore,
) : ViewModel() {

    private val _state = MutableStateFlow(DownloadsHubState())
    val state: StateFlow<DownloadsHubState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            offlineDownloadManager.progressByBookId.collect { progressById ->
                val sorted = progressById.values
                    .sortedWith(Comparator { a, b -> NaturalSort.compare(a.title, b.title) })
                val active = sorted.filter {
                    it.status == OfflineDownloadStatus.DOWNLOADING || it.status == OfflineDownloadStatus.QUEUED
                }
                val terminal = sorted.filter {
                    it.status == OfflineDownloadStatus.FAILED || it.status == OfflineDownloadStatus.CANCELLED
                }
                _state.update { it.copy(activeDownloads = active, terminalDownloads = terminal) }
            }
        }

        viewModelScope.launch {
            combine(
                offlineDownloadManager.downloadedBookIds,
                comicOfflineService.downloadedBookIds,
            ) { _, _ -> Unit }.collect { refresh() }
        }
        viewModelScope.launch {
            prefs.autoDeleteFinishedBooks.collect { value ->
                _state.update { it.copy(autoDeleteFinishedBooks = value) }
            }
        }
        viewModelScope.launch {
            prefs.autoDeleteFailedDownloads.collect { value ->
                _state.update { it.copy(autoDeleteFailedDownloads = value) }
            }
        }
        viewModelScope.launch {
            prefs.seriesPreDownloadCount.collect { value ->
                _state.update { it.copy(seriesPreDownloadCount = value) }
            }
        }
        viewModelScope.launch {
            prefs.downloadOnCellular.collect { value ->
                _state.update { it.copy(downloadOnCellular = value) }
            }
        }
        viewModelScope.launch {
            keepNextOfflineStore.settings.collect { settings ->
                _state.update {
                    it.copy(
                        keepNextOfflineEnabled = settings.enabled,
                        keepNextOfflineCount = settings.count,
                    )
                }
            }
        }
        refresh()
    }

    fun setAutoDeleteFinishedBooks(value: Boolean) {
        viewModelScope.launch { prefs.setAutoDeleteFinishedBooks(value) }
    }

    fun setAutoDeleteFailedDownloads(value: Boolean) {
        viewModelScope.launch { prefs.setAutoDeleteFailedDownloads(value) }
    }

    fun setDownloadOnCellular(value: Boolean) {
        viewModelScope.launch { prefs.setDownloadOnCellular(value) }
    }

    fun setSeriesPreDownloadCount(value: Int) {
        viewModelScope.launch { prefs.setSeriesPreDownloadCount(value) }
    }

    fun setKeepNextOfflineEnabled(value: Boolean) {
        viewModelScope.launch { keepNextOfflineStore.setEnabled(value) }
    }

    fun setKeepNextOfflineCount(value: Int) {
        viewModelScope.launch { keepNextOfflineStore.setCount(value) }
    }

    fun refresh() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }

            val manifests = offlineDownloadManager.listDownloadedManifests()
            val audiobooksResult = repository.getBooks(size = 600)
            val audiobooks = audiobooksResult.fold(
                onSuccess = { serverBooks ->
                    val remoteById = serverBooks.associateBy { it.id }
                    manifests.map { manifest ->

                        val remote = remoteById[manifest.bookId]
                        offlineDownloadManager.ensureCoverCached(
                            remote ?: Book(
                                id = manifest.bookId,
                                title = manifest.title,
                                author = manifest.author,
                                coverUrl = manifest.coverUrl,
                                source = runCatching { BookSource.valueOf(manifest.source) }.getOrDefault(BookSource.GRIMMORY),
                                mediaType = AppMediaType.AUDIOBOOK,
                            )
                        )
                        val cover = offlineDownloadManager.localCoverUri(manifest.bookId)
                            ?: manifest.coverUrl ?: remote?.coverUrl
                        remote?.copy(isDownloaded = true, downloadProgress = 1f, coverUrl = cover)
                            ?: Book(
                                id = manifest.bookId,
                                title = manifest.title,
                                author = manifest.author,
                                coverUrl = cover,
                                source = runCatching { BookSource.valueOf(manifest.source) }.getOrDefault(BookSource.GRIMMORY),
                                mediaType = AppMediaType.AUDIOBOOK,
                                isDownloaded = true,
                                downloadProgress = 1f,
                                duration = manifest.tracks.sumOf { it.durationMs } / 1000,
                            )
                    }
                },
                onFailure = {
                    manifests.map { manifest ->
                        Book(
                            id = manifest.bookId,
                            title = manifest.title,
                            author = manifest.author,
                            coverUrl = offlineDownloadManager.localCoverUri(manifest.bookId) ?: manifest.coverUrl,
                            source = runCatching { BookSource.valueOf(manifest.source) }.getOrDefault(BookSource.GRIMMORY),
                            mediaType = AppMediaType.AUDIOBOOK,
                            isDownloaded = true,
                            downloadProgress = 1f,
                            duration = manifest.tracks.sumOf { it.durationMs } / 1000,
                        )
                    }
                },
            )

            val comicManifests = comicOfflineService.listDownloadedManifests()
            val comicsFromManifests = comicManifests.map { manifest ->
                val enriched = bookCacheDao.getById(manifest.id)?.toBook()
                (enriched ?: manifest).copy(isDownloaded = true, downloadProgress = 1f)
            }

            val seenIds = comicsFromManifests.mapTo(mutableSetOf()) { it.id }
            val legacyComics = comicOfflineService.downloadedBookIds.value
                .filterNot { it in seenIds }
                .map { bookId ->
                    bookCacheDao.getById(bookId)?.toBook()?.copy(isDownloaded = true, downloadProgress = 1f)
                        ?: Book(
                            id = bookId,
                            title = bookId,
                            source = BookSource.GRIMMORY,
                            mediaType = AppMediaType.EBOOK,
                            isDownloaded = true,
                            downloadProgress = 1f,
                        )
                }
            val comics = comicsFromManifests + legacyComics

            val audiobookError = audiobooksResult.exceptionOrNull()
            _state.update {
                it.copy(
                    isLoading = false,
                    downloadedBooks = (audiobooks + comics).sortedWith(Comparator { a, b -> NaturalSort.compare(a.title, b.title) }),
                    error = if (audiobookError != null && audiobooks.isEmpty()) audiobookError.message else null,
                )
            }
        }
    }

    fun removeItem(bookId: String) {

        offlineDownloadManager.removeDownload(bookId)
        comicOfflineService.removeDownload(bookId)
        _state.update { s -> s.copy(downloadedBooks = s.downloadedBooks.filterNot { it.id == bookId }) }
    }

    fun cancelActiveDownload(bookId: String) {
        offlineDownloadManager.cancelDownload(bookId)
    }

    fun retryDownload(bookId: String) {
        val allowCellular = _state.value.downloadOnCellular
        val queued = offlineDownloadManager.retryDownload(bookId, allowCellular)
        if (!queued) {
            _state.update { it.copy(error = "Download request is no longer available.") }
        }
    }
}
