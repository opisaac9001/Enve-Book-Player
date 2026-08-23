package com.enve.app.viewmodel

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.data.offline.ComicOfflineService
import com.enve.app.data.offline.OfflineDownloadManager
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale
import javax.inject.Inject

data class StorageHubState(
    val cacheSizeMb: String = "0.0",
    val appDataSizeMb: String = "0.0",
    val downloadedSizeMb: String = "0.0",
    val downloadedItems: Int = 0,
    val isLoading: Boolean = false,
    val isClearingCache: Boolean = false,
    val isClearingDownloads: Boolean = false,
    val error: String? = null,
)

@HiltViewModel
class StorageHubViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    private val offlineDownloadManager: OfflineDownloadManager,
    private val comicOfflineService: ComicOfflineService,
) : ViewModel() {

    private val _state = MutableStateFlow(StorageHubState())
    val state: StateFlow<StorageHubState> = _state.asStateFlow()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            try {

                val audioCount = withContext(Dispatchers.IO) {
                    offlineDownloadManager.listDownloadedManifests().size
                }
                val comicCount = comicOfflineService.downloadedBookIds.value.size
                val downloadedCount = audioCount + comicCount
                val cacheBytes = withContext(Dispatchers.IO) { directorySize(context.cacheDir) }
                val downloadedBytes = withContext(Dispatchers.IO) {
                    directorySize(java.io.File(context.filesDir, "offline-audio")) +
                        directorySize(java.io.File(context.filesDir, "offline-comics"))
                }
                val appDataBytes = withContext(Dispatchers.IO) {
                    (directorySize(context.filesDir) - downloadedBytes).coerceAtLeast(0L)
                }

                _state.update {
                    it.copy(
                        isLoading = false,
                        downloadedItems = downloadedCount,
                        cacheSizeMb = bytesToMb(cacheBytes),
                        appDataSizeMb = bytesToMb(appDataBytes),
                        downloadedSizeMb = bytesToMb(downloadedBytes),
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update {
                    it.copy(
                        isLoading = false,
                        error = e.message ?: "Failed to read storage metrics",
                    )
                }
            }
        }
    }

    fun clearCache() {
        viewModelScope.launch {
            _state.update { it.copy(isClearingCache = true, error = null) }
            try {
                withContext(Dispatchers.IO) {
                    context.cacheDir.deleteRecursively()
                    context.cacheDir.mkdirs()
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Failed to clear cache") }
            }
            _state.update { it.copy(isClearingCache = false) }
            refresh()
        }
    }

    fun clearDownloads() {
        viewModelScope.launch {
            _state.update { it.copy(isClearingDownloads = true, error = null) }
            try {
                withContext(Dispatchers.IO) {
                    offlineDownloadManager.listDownloadedManifests()
                        .forEach { offlineDownloadManager.removeDownload(it.bookId) }
                    comicOfflineService.listDownloadedManifests()
                        .forEach { comicOfflineService.removeDownload(it.id) }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Failed to remove downloads") }
            }
            _state.update { it.copy(isClearingDownloads = false) }
            refresh()
        }
    }

    private fun directorySize(file: java.io.File?): Long {
        if (file == null || !file.exists()) return 0L
        if (file.isFile) return file.length()
        return file.listFiles()?.sumOf { child -> directorySize(child) } ?: 0L
    }

    private fun bytesToMb(bytes: Long): String {
        val mb = bytes.toDouble() / (1024.0 * 1024.0)
        return String.format(Locale.US, "%.1f", mb)
    }
}
