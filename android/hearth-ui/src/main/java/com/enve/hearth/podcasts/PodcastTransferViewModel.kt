package com.enve.hearth.podcasts

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.engine.podcasts.PodcastExportResult
import com.enve.engine.podcasts.PodcastImportPreview
import com.enve.engine.podcasts.PodcastImportReport
import com.enve.engine.podcasts.PodcastOpmlError
import com.enve.engine.podcasts.PodcastOpmlException
import com.enve.engine.podcasts.PodcastOpmlLimits
import com.enve.engine.podcasts.PodcastsFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import javax.inject.Inject

private const val SAVE_FAILED = "The file couldn't be saved. Choose another location and try again."

data class PodcastTransferProgress(val completed: Int, val total: Int)

data class PodcastTransferUiState(
    val isReadingFile: Boolean = false,
    val preview: PodcastImportPreview? = null,
    val selection: Set<String> = emptySet(),
    val importProgress: PodcastTransferProgress? = null,
    val report: PodcastImportReport? = null,
    val importInterrupted: Boolean = false,
    val importError: String? = null,
    val includeProgress: Boolean = true,
    val includePrivateFeeds: Boolean = false,
    val exportProgress: PodcastTransferProgress? = null,
    val export: PodcastExportResult? = null,
    val exportSaved: Boolean = false,
    val exportError: String? = null,
) {
    val isImporting: Boolean get() = importProgress != null
    val isExporting: Boolean get() = exportProgress != null
}

@HiltViewModel
class PodcastTransferViewModel @Inject constructor(
    private val podcasts: PodcastsFacade,
) : ViewModel() {
    private val mutableState = MutableStateFlow(PodcastTransferUiState())
    val state: StateFlow<PodcastTransferUiState> = mutableState.asStateFlow()
    private var importJob: Job? = null
    private var exportJob: Job? = null

    fun preview(open: () -> InputStream?) {
        if (mutableState.value.isImporting) return
        importJob?.cancel()
        mutableState.update {
            it.copy(isReadingFile = true, preview = null, selection = emptySet(), report = null, importInterrupted = false, importError = null)
        }
        importJob = viewModelScope.launch {
            try {
                val bytes = withContext(Dispatchers.IO) { readBounded(open) }
                val preview = podcasts.previewPodcastImport(bytes)
                mutableState.update { it.copy(isReadingFile = false, preview = preview, selection = preview.defaultSelection) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: PodcastOpmlException) {
                mutableState.update { it.copy(isReadingFile = false, importError = e.message) }
            } catch (_: IOException) {
                mutableState.update { it.copy(isReadingFile = false, importError = PodcastOpmlError.UNREADABLE.message) }
            } catch (_: SecurityException) {
                mutableState.update { it.copy(isReadingFile = false, importError = PodcastOpmlError.UNREADABLE.message) }
            }
        }
    }

    fun toggle(key: String) = mutableState.update {
        it.copy(selection = if (key in it.selection) it.selection - key else it.selection + key)
    }

    fun selectAll() = mutableState.update { state ->
        state.copy(selection = state.preview?.candidates?.mapTo(mutableSetOf()) { it.key }.orEmpty())
    }

    fun selectNone() = mutableState.update { it.copy(selection = emptySet()) }

    fun startImport() {
        val state = mutableState.value
        val preview = state.preview ?: return
        if (state.isImporting || state.selection.isEmpty()) return
        mutableState.update { it.copy(importProgress = PodcastTransferProgress(0, 0), importError = null) }
        importJob = viewModelScope.launch {
            try {
                val report = podcasts.importPodcasts(preview, state.selection) { completed, total ->
                    mutableState.update { it.copy(importProgress = PodcastTransferProgress(completed, total)) }
                }
                mutableState.update { it.copy(importProgress = null, preview = null, selection = emptySet(), report = report) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableState.update { it.copy(importProgress = null, importError = "The import couldn't finish. Shows already added are kept.") }
            }
        }
    }

    fun cancelImport() {
        if (!mutableState.value.isImporting) return
        importJob?.cancel()
        importJob = null
        mutableState.update { it.copy(importProgress = null, preview = null, selection = emptySet(), importInterrupted = true) }
    }

    fun dismissImport() {
        importJob?.cancel()
        importJob = null
        mutableState.update {
            it.copy(isReadingFile = false, preview = null, selection = emptySet(), importProgress = null, report = null, importInterrupted = false, importError = null)
        }
    }

    fun setIncludeProgress(include: Boolean) = mutableState.update { it.copy(includeProgress = include, export = null, exportSaved = false) }

    fun setIncludePrivateFeeds(include: Boolean) = mutableState.update { it.copy(includePrivateFeeds = include, export = null, exportSaved = false) }

    fun prepareExport() {
        val state = mutableState.value
        if (state.isExporting) return
        mutableState.update { it.copy(exportProgress = PodcastTransferProgress(0, 0), export = null, exportSaved = false, exportError = null) }
        exportJob = viewModelScope.launch {
            try {
                val export = podcasts.exportPodcasts(state.includePrivateFeeds, state.includeProgress) { completed, total ->
                    mutableState.update { it.copy(exportProgress = PodcastTransferProgress(completed, total)) }
                }
                mutableState.update { it.copy(exportProgress = null, export = export) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableState.update { it.copy(exportProgress = null, exportError = "The export couldn't be prepared.") }
            }
        }
    }

    fun cancelExport() {
        exportJob?.cancel()
        exportJob = null
        mutableState.update { it.copy(exportProgress = null) }
    }

    fun saveExport(open: () -> OutputStream?) {
        val export = mutableState.value.export ?: return
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    (open() ?: throw IOException("No destination")).use { it.write(export.opml) }
                }
                mutableState.update { it.copy(exportSaved = true, exportError = null) }
            } catch (e: CancellationException) {
                throw e
            } catch (_: IOException) {
                mutableState.update { it.copy(exportError = SAVE_FAILED) }
            } catch (_: SecurityException) {
                mutableState.update { it.copy(exportError = SAVE_FAILED) }
            }
        }
    }

    private fun readBounded(open: () -> InputStream?): ByteArray {
        val input = open() ?: throw IOException("No source")
        return input.use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (output.size() <= PodcastOpmlLimits.MAX_BYTES) {
                val read = stream.read(buffer)
                if (read < 0) break
                output.write(buffer, 0, read)
            }
            output.toByteArray()
        }
    }
}
