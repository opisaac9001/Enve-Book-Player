package com.enve.app.webimport

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

class WebStoryImportViewModel(application: Application) : AndroidViewModel(application) {

    private val root = File(application.cacheDir, WORK_DIRECTORY)
    private val session = WebStoryImportSession(viewModelScope, WebStoryImporter(), File(root, UUID.randomUUID().toString()))

    val state: StateFlow<WebStoryImportUiState> = session.state

    init {
        viewModelScope.launch(Dispatchers.IO) {
            val cutoff = System.currentTimeMillis() - TimeUnit.HOURS.toMillis(STALE_HOURS)
            root.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.deleteRecursively() }
        }
    }

    fun preview(input: String) = session.preview(input)

    fun previewCaptured(url: String, html: String) = session.previewCaptured(url, html)

    fun import(scope: WebStoryScope, onImport: suspend (File) -> Unit) = session.import(scope, onImport)

    fun cancel() = session.cancel()

    fun startOver() = session.startOver()

    override fun onCleared() = session.close()

    private companion object {
        const val WORK_DIRECTORY = "web-story-import"
        const val STALE_HOURS = 6L
    }
}
