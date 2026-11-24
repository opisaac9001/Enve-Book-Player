package com.enve.hearth.readwise

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.engine.readwise.ReadwiseExportPreview
import com.enve.engine.readwise.ReadwiseExportProgress
import com.enve.engine.readwise.ReadwiseExportResult
import com.enve.engine.readwise.ReadwiseExportScope
import com.enve.engine.readwise.ReadwiseFacade
import com.enve.engine.readwise.ReadwiseFailure
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

enum class ReadwiseAccountCheck { CHECKING, VERIFIED }

data class ReadwiseUiState(
    val scope: ReadwiseExportScope? = null,
    val tokenInput: String = "",
    val connecting: Boolean = false,
    val accountCheck: ReadwiseAccountCheck? = null,
    val accountFailure: ReadwiseFailure? = null,
    val preview: ReadwiseExportPreview? = null,
    val loadingPreview: Boolean = false,
    val confirmingExport: Boolean = false,
    val progress: ReadwiseExportProgress? = null,
    val result: ReadwiseExportResult? = null,
) {
    val exporting: Boolean get() = progress != null
}

@HiltViewModel
class ReadwiseViewModel @Inject constructor(
    private val readwise: ReadwiseFacade,
) : ViewModel() {

    val isConnected: StateFlow<Boolean> = readwise.isConnected

    private val mutableState = MutableStateFlow(ReadwiseUiState())
    val state: StateFlow<ReadwiseUiState> = mutableState.asStateFlow()

    private var previewJob: Job? = null
    private var exportJob: Job? = null

    fun setScope(scope: ReadwiseExportScope) {
        if (mutableState.value.scope == scope) return
        mutableState.update { it.copy(scope = scope, preview = null, result = null) }
        refreshPreview()
    }

    fun updateToken(value: String) {
        mutableState.update { it.copy(tokenInput = value, accountFailure = null) }
    }

    fun connect() {
        val token = mutableState.value.tokenInput
        if (token.isBlank() || mutableState.value.connecting) return
        mutableState.update { it.copy(connecting = true, accountFailure = null, accountCheck = null) }
        viewModelScope.launch {
            val failure = readwise.connect(token)
            mutableState.update {
                it.copy(
                    connecting = false,
                    tokenInput = if (failure == null) "" else it.tokenInput,
                    accountFailure = failure,
                    accountCheck = if (failure == null) ReadwiseAccountCheck.VERIFIED else null,
                )
            }
            if (failure == null) refreshPreview()
        }
    }

    fun validate() {
        if (mutableState.value.accountCheck == ReadwiseAccountCheck.CHECKING) return
        mutableState.update { it.copy(accountCheck = ReadwiseAccountCheck.CHECKING, accountFailure = null) }
        viewModelScope.launch {
            val failure = readwise.validate()
            mutableState.update {
                it.copy(
                    accountCheck = if (failure == null) ReadwiseAccountCheck.VERIFIED else null,
                    accountFailure = failure,
                )
            }
        }
    }

    fun disconnect() {
        exportJob?.cancel()
        readwise.disconnect()
        mutableState.update {
            it.copy(accountCheck = null, accountFailure = null, confirmingExport = false, progress = null, result = null)
        }
        refreshPreview()
    }

    fun refreshPreview() {
        val scope = mutableState.value.scope ?: return
        previewJob?.cancel()
        mutableState.update { it.copy(loadingPreview = true) }
        previewJob = viewModelScope.launch {
            val preview = readwise.preview(scope)
            mutableState.update { it.copy(preview = preview, loadingPreview = false) }
        }
    }

    fun requestExport() {
        val preview = mutableState.value.preview ?: return
        if (preview.readyCount == 0 || mutableState.value.exporting || !isConnected.value) return
        mutableState.update { it.copy(confirmingExport = true, result = null) }
    }

    fun dismissExport() {
        mutableState.update { it.copy(confirmingExport = false) }
    }

    fun confirmExport() {
        val scope = mutableState.value.scope ?: return
        if (mutableState.value.exporting) return
        mutableState.update { it.copy(confirmingExport = false, progress = ReadwiseExportProgress(0, 0), result = null) }
        exportJob = viewModelScope.launch {
            try {
                val result = readwise.export(scope) { progress ->
                    mutableState.update { it.copy(progress = progress) }
                }
                mutableState.update { it.copy(result = result) }
            } finally {
                mutableState.update { it.copy(progress = null) }
                refreshPreview()
            }
        }
    }

    fun cancelExport() {
        exportJob?.cancel()
    }

    fun dismissResult() {
        mutableState.update { it.copy(result = null) }
    }
}
