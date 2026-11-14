package com.enve.app.webimport

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.io.IOException
import java.util.UUID

sealed interface WebStoryImportUiState {
    data class Entry(val error: String? = null) : WebStoryImportUiState
    data object Loading : WebStoryImportUiState
    data class Ready(val preview: WebStoryPreview, val error: String? = null) : WebStoryImportUiState
    data class Importing(val preview: WebStoryPreview, val progress: WebStoryImportProgress?) : WebStoryImportUiState
    data class Saving(val title: String) : WebStoryImportUiState
    data class Saved(val title: String, val chapters: Int) : WebStoryImportUiState
}

internal class WebStoryImportSession(
    private val scope: CoroutineScope,
    private val importer: WebStoryImporter,
    private val workDir: File,
) {
    private val _state = MutableStateFlow<WebStoryImportUiState>(WebStoryImportUiState.Entry())
    val state: StateFlow<WebStoryImportUiState> = _state.asStateFlow()

    @Volatile
    private var generation = 0
    private var job: Job? = null
    private var operationDir: File? = null

    fun preview(input: String) = startPreview { dir -> importer.preview(input, dir) }

    fun previewCaptured(url: String, html: String) = startPreview { importer.previewCaptured(url, html) }

    fun import(scopeChoice: WebStoryScope, onImport: suspend (File) -> Unit) {
        val ready = _state.value as? WebStoryImportUiState.Ready ?: return
        val dir = operationDir ?: return
        val token = supersede()
        _state.value = WebStoryImportUiState.Importing(ready.preview, null)
        job = scope.launch {
            val result = try {
                importer.import(ready.preview, scopeChoice, dir) { progress ->
                    if (token == generation) {
                        _state.update { current ->
                            if (current is WebStoryImportUiState.Importing) current.copy(progress = progress) else current
                        }
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: WebStoryImportException) {
                publish(token, ready.copy(error = e.displayMessage))
                return@launch
            } catch (_: IOException) {
                publish(token, ready.copy(error = FILE_FAILED))
                return@launch
            }
            publish(token, WebStoryImportUiState.Saving(result.title))
            val saved = try {
                onImport(result.file)
                true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                false
            } finally {
                result.file.delete()
            }
            if (token != generation) return@launch
            if (saved) {
                discardOperation()
                publish(token, WebStoryImportUiState.Saved(result.title, result.chapters))
            } else if (ready.preview is WebStoryPreview.Download) {
                discardOperation()
                publish(token, WebStoryImportUiState.Entry(COMMIT_FAILED))
            } else {
                publish(token, ready.copy(error = COMMIT_FAILED))
            }
        }
    }

    fun cancel() {
        val current = _state.value
        supersede()
        _state.value = when (current) {
            is WebStoryImportUiState.Loading -> WebStoryImportUiState.Entry()
            is WebStoryImportUiState.Importing -> WebStoryImportUiState.Ready(current.preview)
            else -> current
        }
    }

    fun startOver() {
        supersede()
        discardOperation()
        _state.value = WebStoryImportUiState.Entry()
    }

    fun close() {
        supersede()
        workDir.deleteRecursively()
    }

    private fun startPreview(load: suspend (File) -> WebStoryPreview) {
        val token = supersede()
        discardOperation()
        val dir = File(workDir, UUID.randomUUID().toString()).also { operationDir = it }
        _state.value = WebStoryImportUiState.Loading
        job = scope.launch {
            val next = try {
                WebStoryImportUiState.Ready(load(dir))
            } catch (e: CancellationException) {
                dir.deleteRecursively()
                throw e
            } catch (e: WebStoryImportException) {
                dir.deleteRecursively()
                WebStoryImportUiState.Entry(e.displayMessage)
            } catch (_: IOException) {
                dir.deleteRecursively()
                WebStoryImportUiState.Entry(FILE_FAILED)
            }
            publish(token, next)
        }
    }

    private fun supersede(): Int {
        job?.cancel()
        job = null
        return ++generation
    }

    private fun publish(token: Int, next: WebStoryImportUiState) {
        if (token == generation) _state.value = next
    }

    private fun discardOperation() {
        operationDir?.deleteRecursively()
        operationDir = null
    }

    private companion object {
        const val FILE_FAILED = "Enve couldn’t save the temporary file. Check the available storage and try again."
        const val COMMIT_FAILED = "Enve couldn't add the book to the library. Try again."
    }
}
