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
import com.enve.app.data.offline.ComicDownloadProgress
import com.enve.app.data.offline.ComicDownloadStatus
import com.enve.app.data.offline.ComicOfflineService
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.offline.OfflineDownloadProgress
import com.enve.app.data.offline.OfflineDownloadStatus
import com.enve.app.data.offline.offlineDownloadKey
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
    val downloadKeys: Map<String, String> = emptyMap(),
    val activeDownloads: List<OfflineDownloadProgress> = emptyList(),
    val activeComicDownloads: List<ComicDownloadProgress> = emptyList(),
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

val Book.downloadEntryId: String get() = "${mediaType.name}:$uniqueKey"

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
            offlineDownloadManager.progressByDownloadKey.collect { progressById ->
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
            comicOfflineService.progressByDownloadKey.collect { progressById ->
                val active = progressById.values
                    .filter { it.status == ComicDownloadStatus.DOWNLOADING || it.status == ComicDownloadStatus.QUEUED }
                    .sortedWith(Comparator { a, b -> NaturalSort.compare(a.title, b.title) })
                _state.update { it.copy(activeComicDownloads = active) }
            }
        }

        viewModelScope.launch {
            combine(
                offlineDownloadManager.downloadedKeys,
                comicOfflineService.downloadedKeys,
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
            val remoteByKey = audiobooksResult.getOrNull().orEmpty().associateBy { it.offlineDownloadKey }
            val audiobookKeys = mutableMapOf<String, String>()
            val audiobooks = manifests.map { manifest ->
                val remote = remoteByKey[manifest.downloadKey]
                val local = Book(
                    id = manifest.bookId,
                    title = manifest.title,
                    author = manifest.author,
                    coverUrl = manifest.coverUrl,
                    source = runCatching { BookSource.valueOf(manifest.source) }.getOrDefault(BookSource.GRIMMORY),
                    mediaType = AppMediaType.AUDIOBOOK,
                    connectionId = manifest.connectionId,
                    duration = manifest.tracks.sumOf { it.durationMs } / 1000,
                )
                if (audiobooksResult.isSuccess) offlineDownloadManager.ensureCoverCached(remote ?: local)
                val cover = offlineDownloadManager.localCoverUri(manifest.downloadKey)
                    ?: manifest.coverUrl ?: remote?.coverUrl
                (remote ?: local).copy(mediaType = AppMediaType.AUDIOBOOK, isDownloaded = true, downloadProgress = 1f, coverUrl = cover)
                    .also { audiobookKeys[it.downloadEntryId] = manifest.downloadKey }
            }

            val comicKeys = mutableMapOf<String, String>()
            val comics = comicOfflineService.listDownloadedManifests().map { manifest ->
                val enriched = bookCacheDao.getByCacheKey(manifest.uniqueKey)?.toBook()
                (enriched ?: manifest).copy(mediaType = AppMediaType.EBOOK, isDownloaded = true, downloadProgress = 1f)
                    .also { comicKeys[it.downloadEntryId] = manifest.offlineDownloadKey }
            }

            val audiobookError = audiobooksResult.exceptionOrNull()
            _state.update {
                it.copy(
                    isLoading = false,
                    downloadedBooks = (audiobooks + comics).sortedWith(Comparator { a, b -> NaturalSort.compare(a.title, b.title) }),
                    downloadKeys = audiobookKeys + comicKeys,
                    error = if (audiobookError != null && audiobooks.isEmpty()) audiobookError.message else null,
                )
            }
        }
    }

    fun removeItem(entryId: String) {
        val current = _state.value
        val book = current.downloadedBooks.firstOrNull { it.downloadEntryId == entryId }
        val key = current.downloadKeys[entryId] ?: entryId
        if (book?.mediaType == AppMediaType.EBOOK) {
            comicOfflineService.removeDownload(key)
        } else {
            offlineDownloadManager.removeDownload(key)
        }
        _state.update { s -> s.copy(downloadedBooks = s.downloadedBooks.filterNot { it.downloadEntryId == entryId }) }
    }

    fun cancelActiveDownload(downloadKey: String) {
        offlineDownloadManager.cancelDownload(downloadKey)
    }

    fun cancelComicDownload(downloadKey: String) {
        comicOfflineService.cancelDownload(downloadKey)
    }

    fun retryDownload(downloadKey: String) {
        val allowCellular = _state.value.downloadOnCellular
        val queued = offlineDownloadManager.retryDownload(downloadKey, allowCellular)
        if (!queued) {
            _state.update { it.copy(error = "Download request is no longer available.") }
        }
    }
}
