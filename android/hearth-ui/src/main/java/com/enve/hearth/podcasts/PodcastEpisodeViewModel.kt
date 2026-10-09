package com.enve.hearth.podcasts

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.Book
import com.enve.engine.library.LibraryDownloadState
import com.enve.engine.library.LibraryDownloadStatus
import com.enve.engine.library.LibraryFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class PodcastEpisodeViewModel @Inject constructor(
    private val library: LibraryFacade,
) : ViewModel() {
    private val mutableDownload = MutableStateFlow(LibraryDownloadState())
    val download: StateFlow<LibraryDownloadState> = mutableDownload
    private var downloadJob: Job? = null

    fun load(episode: Book) {
        downloadJob?.cancel()
        downloadJob = viewModelScope.launch {
            library.downloadState(episode.id).collect { mutableDownload.value = it }
        }
    }

    fun toggleDownload(episode: Book) {
        viewModelScope.launch {
            if (mutableDownload.value.status == LibraryDownloadStatus.COMPLETED) {
                library.removeDownload(episode)
            } else if (!mutableDownload.value.isActive) {
                library.download(episode)
            }
        }
    }
}
