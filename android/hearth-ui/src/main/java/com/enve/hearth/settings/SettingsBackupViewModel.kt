package com.enve.hearth.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.engine.backup.SettingsTransferFacade
import com.enve.engine.backup.SettingsBackupFacade
import com.enve.engine.backup.SettingsExportResult
import com.enve.engine.backup.SettingsImportInspection
import com.enve.engine.backup.SettingsImportPreview
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class SettingsBackupUiState(
    val exporting: Boolean = false,
    val inspecting: Boolean = false,
    val applying: Boolean = false,
    val exportResult: SettingsExportResult? = null,
    val rejection: SettingsImportInspection.Rejected? = null,
    val preview: SettingsImportPreview? = null,
    val importedCount: Int? = null,
    val importFailed: Boolean = false,
) {
    val busy: Boolean get() = exporting || inspecting || applying
}

@HiltViewModel
class SettingsBackupViewModel @Inject constructor(
    private val backup: SettingsBackupFacade,
    internal val transfer: SettingsTransferFacade? = null,
) : ViewModel() {

    private val mutableState = MutableStateFlow(SettingsBackupUiState())
    val state: StateFlow<SettingsBackupUiState> = mutableState.asStateFlow()

    private var inspection: Job? = null

    fun export(destinationUri: String) {
        if (mutableState.value.busy) return
        mutableState.update { SettingsBackupUiState(exporting = true) }
        viewModelScope.launch {
            try {
                val result = backup.export(destinationUri)
                mutableState.update { it.copy(exportResult = result) }
            } finally {
                mutableState.update { it.copy(exporting = false) }
            }
        }
    }

    fun inspect(sourceUri: String) {
        if (mutableState.value.busy) return
        mutableState.update { SettingsBackupUiState(inspecting = true) }
        inspection = viewModelScope.launch {
            try {
                when (val result = backup.inspect(sourceUri)) {
                    is SettingsImportInspection.Ready -> mutableState.update { it.copy(preview = result.preview) }
                    is SettingsImportInspection.Rejected -> mutableState.update { it.copy(rejection = result) }
                }
            } finally {
                mutableState.update { it.copy(inspecting = false) }
            }
        }
    }

    fun cancelInspection() {
        inspection?.cancel()
    }

    fun confirmImport() {
        val preview = mutableState.value.preview ?: return
        if (mutableState.value.applying || preview.changes.isEmpty()) return
        mutableState.update { it.copy(applying = true) }
        viewModelScope.launch {
            try {
                val applied = backup.apply(preview.backup)
                mutableState.update {
                    it.copy(
                        preview = null,
                        importedCount = preview.changes.size.takeIf { applied },
                        importFailed = !applied,
                    )
                }
            } finally {
                mutableState.update { it.copy(applying = false) }
            }
        }
    }

    fun dismissPreview() {
        if (mutableState.value.applying) return
        mutableState.update { it.copy(preview = null) }
    }
}
