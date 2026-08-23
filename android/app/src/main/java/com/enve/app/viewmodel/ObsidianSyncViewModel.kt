package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.data.obsidian.ObsidianExportService
import com.enve.app.data.repository.AnnotationRepository
import com.enve.core.data.local.PreferencesManager
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class ObsidianSyncState(
    val treeUri: String? = null,
    val annotationCount: Int = 0,
    val isExporting: Boolean = false,
    val message: String? = null,
    val error: String? = null,
)

@HiltViewModel
class ObsidianSyncViewModel @Inject constructor(
    private val prefs: PreferencesManager,
    private val exportService: ObsidianExportService,
    annotationRepository: AnnotationRepository,
) : ViewModel() {
    private val localState = MutableStateFlow(ObsidianSyncState())

    val state: StateFlow<ObsidianSyncState> = combine(
        prefs.obsidianTreeUri,
        annotationRepository.all().map { rows -> rows.count { it.deletedAt == null } },
        localState,
    ) { treeUri, annotationCount, local ->
        local.copy(treeUri = treeUri, annotationCount = annotationCount)
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = ObsidianSyncState(),
    )

    fun setVaultUri(uri: String) {
        viewModelScope.launch {
            prefs.setObsidianTreeUri(uri)
            localState.update { it.copy(message = "Vault selected", error = null) }
        }
    }

    fun clearVault() {
        viewModelScope.launch {
            prefs.setObsidianTreeUri(null)
            localState.update { it.copy(message = "Vault disconnected", error = null) }
        }
    }

    fun exportNow() {
        val uri = state.value.treeUri ?: run {
            localState.update { it.copy(error = "Choose a vault folder first") }
            return
        }
        if (localState.value.isExporting) return
        viewModelScope.launch {
            localState.update { it.copy(isExporting = true, message = null, error = null) }
            try {
                val result = exportService.exportAll(uri)
                localState.update {
                    it.copy(
                        isExporting = false,
                        message = "Exported ${result.annotationCount} annotations across ${result.bookCount} books",
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                localState.update {
                    it.copy(
                        isExporting = false,
                        error = e.message ?: "Obsidian export failed",
                    )
                }
            }
        }
    }

    fun clearTransientMessage() {
        localState.update { it.copy(message = null, error = null) }
    }
}
