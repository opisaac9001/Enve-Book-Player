package com.enve.app.cloud

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.data.fileimport.AudioGrouping
import com.enve.app.data.fileimport.CompletedFileImporter
import com.enve.app.data.fileimport.DropboxLinkDownloader
import com.enve.app.data.fileimport.DropboxSharedLink
import com.enve.app.data.fileimport.ImportFile
import com.enve.app.data.fileimport.ImportPlanner
import com.enve.app.data.fileimport.ImportableFormats
import com.enve.app.data.fileimport.ImportedFileKind
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileNotFoundException

data class CloudImportProgress(
    val title: String,
    val itemNumber: Int,
    val itemCount: Int,
    val copiedBytes: Long,
    val totalBytes: Long,
)

data class CloudImportUiState(
    val service: CloudStorageService,
    val tree: Uri? = null,
    val path: List<CloudEntry> = emptyList(),
    val entries: List<CloudEntry> = emptyList(),
    val truncated: Boolean = false,
    val providerStillLoading: Boolean = false,
    val selected: Map<String, CloudEntry> = emptyMap(),
    val grouping: AudioGrouping = AudioGrouping.AUTOMATIC,
    val loading: Boolean = false,
    val progress: CloudImportProgress? = null,
    val message: String? = null,
) {
    val browsing: Boolean get() = tree != null
    val selectedFiles: List<CloudEntry> get() = selected.values.filter { it.isImportable }
    val selectedAudioCount: Int get() = selectedFiles.count { ImportableFormats.kind(it.name) == ImportedFileKind.AUDIO }
}

val CloudEntry.isImportable: Boolean get() = !isDirectory && ImportableFormats.kind(name) != null

class CloudImportViewModel(
    private val service: CloudStorageService,
    private val resolver: ContentResolver,
    private val browser: CloudDocumentBrowser,
    private val importer: CompletedFileImporter,
    private val linkDownloader: DropboxLinkDownloader?,
) : ViewModel() {
    private val mutableState = MutableStateFlow(CloudImportUiState(service))
    val state: StateFlow<CloudImportUiState> = mutableState.asStateFlow()
    private var browseJob: Job? = null
    private var importJob: Job? = null

    fun onFilesPicked(uris: List<Uri>) {
        if (uris.isEmpty()) return
        browse {
            val entries = browser.describe(uris.take(ImportPlanner.MAX_FILES))
            mutableState.update { state ->
                state.copy(
                    tree = null,
                    path = emptyList(),
                    entries = entries,
                    truncated = uris.size > ImportPlanner.MAX_FILES,
                    providerStillLoading = false,
                    selected = entries.filter { it.isImportable }.associateBy { it.key },
                )
            }
        }
    }

    fun onFolderPicked(tree: Uri?) {
        if (tree == null) return
        browse { openTree(tree) }
    }

    fun open(entry: CloudEntry) {
        if (!entry.isDirectory) return toggle(entry)
        val current = state.value
        val tree = current.tree ?: return
        browse { load(tree, current.path + entry) }
    }

    fun up(): Boolean {
        val current = state.value
        val tree = current.tree ?: return false
        if (current.path.size <= 1) return false
        browse { load(tree, current.path.dropLast(1)) }
        return true
    }

    fun refresh() {
        val current = state.value
        val tree = current.tree ?: return
        if (current.path.isEmpty()) return
        browse { load(tree, current.path) }
    }

    fun toggle(entry: CloudEntry) {
        if (!entry.isImportable) return
        mutableState.update { state ->
            val selected = if (entry.key in state.selected) state.selected - entry.key else state.selected + (entry.key to entry)
            state.copy(selected = selected)
        }
    }

    fun selectAllVisible() {
        mutableState.update { state ->
            state.copy(selected = state.selected + state.entries.filter { it.isImportable }.associateBy { it.key })
        }
    }

    fun clearSelection() {
        mutableState.update { it.copy(selected = emptyMap()) }
    }

    fun setGrouping(grouping: AudioGrouping) {
        mutableState.update { it.copy(grouping = grouping) }
    }

    fun dismissMessage() {
        mutableState.update { it.copy(message = null) }
    }

    fun cancelImport() {
        importJob?.cancel()
    }

    fun startImport() {
        if (importJob?.isActive == true) return
        val current = state.value
        val selection = current.selectedFiles
        if (selection.isEmpty()) return
        val files = selection.map { entry ->
            ImportFile(entry.name, entry.sizeBytes, identity = entry.key, folder = entry.parent) {
                resolver.openInputStream(entry.uri) ?: throw FileNotFoundException(entry.name)
            }
        }
        val items = try {
            ImportPlanner.plan(files, current.grouping)
        } catch (e: IllegalArgumentException) {
            mutableState.update { it.copy(message = e.message) }
            return
        }
        importJob = viewModelScope.launch {
            val failures = mutableListOf<String>()
            var imported = 0
            try {
                items.forEachIndexed { index, item ->
                    showProgress(item.title, index + 1, items.size, item.files.sumOf { it.sizeBytes.coerceAtLeast(0L) })
                    try {
                        importer.import(item, ::addProgress)
                        imported++
                        val done = item.files.mapNotNull { it.identity }.toSet()
                        mutableState.update { it.copy(selected = it.selected - done) }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        failures += "${item.title}: ${e.message ?: "couldn't be imported"}"
                    }
                }
                mutableState.update { it.copy(message = summary(imported, failures, notImported = 0)) }
            } catch (e: CancellationException) {
                val remaining = items.size - imported - failures.size
                mutableState.update { it.copy(message = "Import cancelled. " + summary(imported, failures, remaining)) }
                throw e
            } finally {
                mutableState.update { it.copy(progress = null) }
            }
        }
    }

    fun importDropboxLink(text: String) {
        val downloader = linkDownloader ?: return
        if (importJob?.isActive == true) return
        val link = try {
            DropboxSharedLink.parse(text)
        } catch (e: IllegalArgumentException) {
            mutableState.update { it.copy(message = e.message) }
            return
        }
        importJob = viewModelScope.launch {
            var downloaded: File? = null
            try {
                showProgress("Downloading ${link.fileName}", 1, 1, -1L)
                val file = downloader.download(link, ::addProgress).also { downloaded = it }
                val item = ImportPlanner.plan(
                    listOf(ImportFile(link.fileName, file.length(), identity = link.identity) { file.inputStream() }),
                    AudioGrouping.SEPARATE,
                ).single()
                showProgress("Adding ${link.fileName}", 1, 1, file.length())
                val book = importer.import(item, ::addProgress)
                mutableState.update { it.copy(message = "Added ${book.title} from Dropbox.") }
            } catch (e: CancellationException) {
                mutableState.update { it.copy(message = "Dropbox import cancelled.") }
                throw e
            } catch (e: Exception) {
                mutableState.update { it.copy(message = e.message ?: "Couldn't import that Dropbox file.") }
            } finally {
                withContext(NonCancellable + Dispatchers.IO) { downloaded?.delete() }
                mutableState.update { it.copy(progress = null) }
            }
        }
    }

    private fun showProgress(title: String, itemNumber: Int, itemCount: Int, totalBytes: Long) {
        mutableState.update {
            it.copy(progress = CloudImportProgress(title, itemNumber, itemCount, copiedBytes = 0L, totalBytes = totalBytes))
        }
    }

    private fun addProgress(bytes: Long) {
        mutableState.update { state -> state.copy(progress = state.progress?.let { it.copy(copiedBytes = it.copiedBytes + bytes) }) }
    }

    private suspend fun openTree(tree: Uri) {
        val root = browser.root(tree)
        mutableState.update {
            it.copy(tree = tree, path = listOf(root), entries = emptyList(), selected = emptyMap(), truncated = false)
        }
        load(tree, listOf(root))
    }

    private suspend fun load(tree: Uri, path: List<CloudEntry>) {
        val listing = browser.children(tree, path.last())
        mutableState.update {
            it.copy(path = path, entries = listing.entries, truncated = listing.truncated, providerStillLoading = listing.providerStillLoading)
        }
    }

    private fun browse(block: suspend () -> Unit) {
        browseJob?.cancel()
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            mutableState.update { it.copy(loading = true) }
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (_: SecurityException) {
                mutableState.update { it.copy(message = "${service.displayName} didn't allow access to that location.") }
            } catch (e: Exception) {
                mutableState.update { it.copy(message = e.message ?: "${service.displayName} couldn't list that folder.") }
            } finally {
                if (browseJob === coroutineContext[Job]) mutableState.update { it.copy(loading = false) }
            }
        }
        browseJob = job
        job.start()
    }

    private fun summary(imported: Int, failures: List<String>, notImported: Int): String = buildString {
        append(if (imported == 1) "Imported 1 book." else "Imported $imported books.")
        if (notImported > 0) append(" $notImported not imported.")
        if (failures.isNotEmpty()) {
            append(" ${failures.size} failed: ")
            append(failures.take(3).joinToString("; "))
            if (failures.size > 3) append("; …")
        }
    }
}

internal val CloudEntry.key: String
    get() = try {
        "${uri.authority}:${DocumentsContract.getDocumentId(uri)}"
    } catch (_: IllegalArgumentException) {
        uri.toString()
    }
