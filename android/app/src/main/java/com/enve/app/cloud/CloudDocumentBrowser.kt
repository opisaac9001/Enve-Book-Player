package com.enve.app.cloud

import android.content.ContentResolver
import android.database.Cursor
import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.enve.app.data.fileimport.ImportFolder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

data class CloudEntry(
    val uri: Uri,
    val documentId: String?,
    val name: String,
    val sizeBytes: Long,
    val isDirectory: Boolean,
    val parent: ImportFolder?,
)

data class CloudListing(
    val entries: List<CloudEntry>,
    val truncated: Boolean,
    val providerStillLoading: Boolean,
)

class CloudDocumentBrowser(private val resolver: ContentResolver) {
    suspend fun root(tree: Uri): CloudEntry = withContext(Dispatchers.IO) {
        val documentId = DocumentsContract.getTreeDocumentId(tree)
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
        val name = query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME)) { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
        CloudEntry(uri, documentId, name?.takeIf { it.isNotBlank() } ?: "Folder", -1L, isDirectory = true, parent = null)
    }

    suspend fun children(tree: Uri, parent: CloudEntry): CloudListing = withContext(Dispatchers.IO) {
        val parentId = requireNotNull(parent.documentId)
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
        )
        val folder = ImportFolder(key = "${tree.authority}\n$parentId", name = parent.name)
        query(uri, projection) { cursor ->
            val entries = ArrayList<CloudEntry>()
            while (entries.size < MAX_ENTRIES && cursor.moveToNext()) {
                val documentId = cursor.getString(0) ?: continue
                val name = cursor.getString(1)?.takeIf { it.isNotBlank() } ?: continue
                entries += CloudEntry(
                    uri = DocumentsContract.buildDocumentUriUsingTree(tree, documentId),
                    documentId = documentId,
                    name = name,
                    sizeBytes = if (cursor.isNull(3)) -1L else cursor.getLong(3),
                    isDirectory = cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR,
                    parent = folder,
                )
            }
            CloudListing(
                entries = entries.sortedWith(compareByDescending<CloudEntry> { it.isDirectory }.thenBy { it.name.lowercase() }),
                truncated = entries.size == MAX_ENTRIES && cursor.position < cursor.count - 1,
                providerStillLoading = cursor.extras?.getBoolean(DocumentsContract.EXTRA_LOADING) == true,
            )
        } ?: CloudListing(emptyList(), truncated = false, providerStillLoading = false)
    }

    suspend fun describe(uris: List<Uri>): List<CloudEntry> = withContext(Dispatchers.IO) {
        uris.mapNotNull { uri ->
            currentCoroutineContext().ensureActive()
            query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)) { cursor ->
                if (!cursor.moveToFirst()) return@query null
                val name = cursor.getString(0)?.takeIf { it.isNotBlank() } ?: return@query null
                CloudEntry(
                    uri = uri,
                    documentId = null,
                    name = name,
                    sizeBytes = if (cursor.isNull(1)) -1L else cursor.getLong(1),
                    isDirectory = false,
                    parent = null,
                )
            }
        }
    }

    private suspend fun <T> query(uri: Uri, projection: Array<String>, read: (Cursor) -> T): T? =
        suspendCancellableCoroutine { continuation ->
            val signal = CancellationSignal()
            continuation.invokeOnCancellation { signal.cancel() }
            try {
                val result = resolver.query(uri, projection, null, null, null, signal)?.use(read)
                continuation.resume(result)
            } catch (error: Exception) {
                continuation.resumeWithException(error)
            }
        }

    private companion object {
        const val MAX_ENTRIES = 2_000
    }
}
