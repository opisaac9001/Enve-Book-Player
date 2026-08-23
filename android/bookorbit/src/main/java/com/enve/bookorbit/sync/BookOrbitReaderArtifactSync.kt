package com.enve.bookorbit.sync

import com.enve.bookorbit.BookOrbitProviderAdapter
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.model.ReaderAnnotationDao
import javax.inject.Inject
import javax.inject.Singleton

data class BookOrbitReaderArtifactSyncResult(
    val pulled: Int,
    val pushed: Int,
)

@Singleton
class BookOrbitReaderArtifactSync @Inject constructor(
    private val adapter: BookOrbitProviderAdapter,
    private val dao: ReaderAnnotationDao,
) {
    suspend fun sync(book: Book): BookOrbitReaderArtifactSyncResult {
        val dirty = dao.getDirtyForBookAndProvider(book.id, PROVIDER_SOURCE)
        var pushed = 0
        if (dirty.isNotEmpty()) {
            val result = adapter.pushAnnotations(book, dirty).getOrThrow()
            result.accepted.forEach { accepted ->
                val local = dirty.firstOrNull { it.id == accepted.id }
                if (local?.deletedAt != null) {
                    dao.purge(accepted.id)
                } else {
                    dao.markClean(accepted.id, accepted.etag, accepted.serverId)
                }
            }
            pushed = result.accepted.size
            if (result.rejected.isNotEmpty()) {
                return BookOrbitReaderArtifactSyncResult(pulled = 0, pushed = pushed)
            }
        }

        val remote = adapter.fetchAnnotations(book).getOrThrow()
        val reconciled = remote.map { record ->
            record.serverId?.let { dao.getByServerId(it, PROVIDER_SOURCE) }
                ?.let { existing -> record.copy(id = existing.id) }
                ?: record
        }
        if (reconciled.isNotEmpty()) dao.upsertAll(reconciled)
        val serverIds = reconciled.mapNotNull(ReaderAnnotation::serverId).distinct()
        if (serverIds.isEmpty()) {
            dao.purgeCleanProviderRows(book.id, PROVIDER_SOURCE)
        } else {
            dao.purgeCleanProviderRowsMissing(book.id, PROVIDER_SOURCE, serverIds)
        }
        return BookOrbitReaderArtifactSyncResult(pulled = reconciled.size, pushed = pushed)
    }

    private companion object {
        const val PROVIDER_SOURCE = "bookorbit"
    }
}
