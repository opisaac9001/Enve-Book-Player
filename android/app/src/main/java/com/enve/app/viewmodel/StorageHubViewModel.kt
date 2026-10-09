package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.data.offline.ComicOfflineService
import com.enve.app.data.offline.OfflineDownloadManager
import dagger.hilt.android.lifecycle.HiltViewModel
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
    val sharedDownloadsSizeMb: String = "0.0",
    val downloadedItems: Int = 0,
    val isLoading: Boolean = false,
    val isClearingCache: Boolean = false,
    val isClearingDownloads: Boolean = false,
    val error: String? = null,
)

@HiltViewModel
class StorageHubViewModel @Inject constructor(
    private val locations: com.enve.core.data.local.ProfileStorageLocations,
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
                val cacheBytes = withContext(Dispatchers.IO) { directorySize(locations.cacheDirectory) }
                val downloadedBytes = withContext(Dispatchers.IO) {
                    directorySize(java.io.File(locations.filesDirectory, "offline-audio")) +
                        directorySize(java.io.File(locations.filesDirectory, "offline-comics"))
                }
                val appDataBytes = withContext(Dispatchers.IO) {
                    (directorySize(locations.filesDirectory) - downloadedBytes).coerceAtLeast(0L)
                }

                val sharedBytes = withContext(Dispatchers.IO) { offlineDownloadManager.sharedStorageBytes() }
                _state.update {
                    it.copy(
                        isLoading = false,
                        sharedDownloadsSizeMb = bytesToMb(sharedBytes),
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
                    privateChildren(locations.cacheDirectory).forEach { check(it.deleteRecursively()) }
                    check(locations.cacheDirectory.isDirectory || locations.cacheDirectory.mkdirs())
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
        if (file == null || !file.exists() || java.nio.file.Files.isSymbolicLink(file.toPath())) return 0L
        if (file.isFile) return file.length()
        return privateChildren(file).sumOf { child -> directorySize(child) }
    }

    private fun privateChildren(directory: java.io.File): List<java.io.File> = directory.listFiles().orEmpty().filterNot {
        locations.profileId == com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID &&
            ((directory == locations.filesDirectory && it.name in setOf("profiles", "shared-downloads")) ||
                (directory == locations.cacheDirectory && it.name == "profiles"))
    }

    private fun bytesToMb(bytes: Long): String {
        val mb = bytes.toDouble() / (1024.0 * 1024.0)
        return String.format(Locale.US, "%.1f", mb)
    }
}
