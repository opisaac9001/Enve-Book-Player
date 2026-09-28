package com.enve.bookorbit.sync

import com.enve.bookorbit.BOOKORBIT_PROVIDER_SOURCE
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.model.ReaderAnnotationDao
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.sync.AcceptedAnnotation
import com.enve.core.data.sync.AnnotationsPushResult
import com.enve.core.data.sync.RejectedAnnotation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BookOrbitReaderArtifactSyncTest {

    private val book = Book(id = "7", title = "Piranesi", source = BookSource.BOOKORBIT)

    @Test
    fun rejectedOutboundRowsDoNotBlockTheInboundPull() = runBlocking {
        val dao = FakeReaderAnnotationDao(
            localHighlight(id = "local-pdf", media = AnnotationMedia.PDF, dirty = true),
        )
        val adapter = FakeProviderAdapter(
            push = { annotations ->
                AnnotationsPushResult(
                    rejected = annotations.map { RejectedAnnotation(it.id, "BookOrbit cannot store this reader artifact") },
                )
            },
            remote = listOf(serverHighlight(serverId = "31")),
        )

        val result = syncBookOrbitReaderArtifacts(book, adapter, dao)

        assertEquals(1, result.pulled)
        assertEquals(0, result.pushed)
        assertEquals("bookorbit:31", dao.getByServerId("31", BOOKORBIT_PROVIDER_SOURCE)?.id)
    }

    @Test
    fun unsupportedLocalArtifactsStayLocalAndDirty() = runBlocking {
        val dao = FakeReaderAnnotationDao(
            localHighlight(id = "local-pdf", media = AnnotationMedia.PDF, dirty = true),
        )
        val adapter = FakeProviderAdapter(
            push = { annotations ->
                AnnotationsPushResult(
                    rejected = annotations.map { RejectedAnnotation(it.id, "BookOrbit cannot store this reader artifact") },
                )
            },
            remote = emptyList(),
        )

        syncBookOrbitReaderArtifacts(book, adapter, dao)

        val survivor = dao.getById("local-pdf")
        assertTrue(survivor != null && survivor.syncDirty)
        assertNull(survivor?.serverId)
    }

    @Test
    fun emptyRemoteResponseDoesNotPurgeLocalRows() = runBlocking {
        val dao = FakeReaderAnnotationDao(
            localHighlight(id = "bookorbit:14", serverId = "14", dirty = false),
            localHighlight(id = "bookorbit:15", serverId = "15", dirty = false),
            localHighlight(id = "local-orphan", serverId = null, dirty = false),
            localHighlight(id = "local-dirty", serverId = null, dirty = true),
        )
        val adapter = FakeProviderAdapter(push = { AnnotationsPushResult() }, remote = emptyList())

        syncBookOrbitReaderArtifacts(book, adapter, dao)

        assertEquals(listOf("bookorbit:14", "bookorbit:15", "local-orphan", "local-dirty"), dao.ids())
    }

    @Test
    fun authoritativeCleanupKeepsRowsTheServerStillReports() = runBlocking {
        val dao = FakeReaderAnnotationDao(
            localHighlight(id = "bookorbit:14", serverId = "14", dirty = false),
            localHighlight(id = "bookorbit:15", serverId = "15", dirty = false),
        )
        val adapter = FakeProviderAdapter(
            push = { AnnotationsPushResult() },
            remote = listOf(serverHighlight(serverId = "15")),
        )

        syncBookOrbitReaderArtifacts(book, adapter, dao)

        assertEquals(listOf("bookorbit:15"), dao.ids())
    }

    @Test
    fun aDirtyLocalEditIsNotOverwrittenByTheRemoteEchoOfARejectedPush() = runBlocking {
        val dao = FakeReaderAnnotationDao(
            localHighlight(id = "bookorbit:31", serverId = "31", dirty = true, note = "my edited note"),
        )
        val adapter = FakeProviderAdapter(
            push = { annotations ->
                AnnotationsPushResult(rejected = annotations.map { RejectedAnnotation(it.id, "server rejected") })
            },
            remote = listOf(serverHighlight(serverId = "31", note = "stale server note")),
        )

        val result = syncBookOrbitReaderArtifacts(book, adapter, dao)

        assertEquals(0, result.pulled)
        val local = dao.getById("bookorbit:31")
        assertEquals("my edited note", local?.note)
        assertTrue(local?.syncDirty == true)
    }

    @Test
    fun acceptedDeletionsArePurgedAndAcceptedEditsAreMarkedClean() = runBlocking {
        val dao = FakeReaderAnnotationDao(
            localHighlight(id = "local-new", serverId = null, dirty = true),
            localHighlight(id = "bookorbit:20", serverId = "20", dirty = true, deletedAt = 1_000L),
        )
        val adapter = FakeProviderAdapter(
            push = {
                AnnotationsPushResult(
                    accepted = listOf(
                        AcceptedAnnotation("local-new", serverId = "21"),
                        AcceptedAnnotation("bookorbit:20", serverId = "20"),
                    ),
                )
            },
            remote = listOf(serverHighlight(serverId = "21")),
        )

        val result = syncBookOrbitReaderArtifacts(book, adapter, dao)

        assertEquals(2, result.pushed)
        assertNull(dao.getById("bookorbit:20"))
        val pushedRow = dao.getById("local-new")
        assertEquals("21", pushedRow?.serverId)
        assertTrue(pushedRow?.syncDirty == false)
    }

    private fun localHighlight(
        id: String,
        serverId: String? = null,
        dirty: Boolean = false,
        media: AnnotationMedia = AnnotationMedia.EPUB,
        note: String = "",
        deletedAt: Long? = null,
    ) = ReaderAnnotation(
        id = id,
        bookId = book.id,
        kind = AnnotationKind.HIGHLIGHT.name,
        media = media.name,
        cfi = "epubcfi(/6/8!/4/2:10)",
        selectedText = "a quoted line",
        note = note,
        serverId = serverId,
        deletedAt = deletedAt,
        providerSource = BOOKORBIT_PROVIDER_SOURCE,
        syncDirty = dirty,
    )

    private fun serverHighlight(serverId: String, note: String = "") = ReaderAnnotation(
        id = "bookorbit:$serverId",
        bookId = book.id,
        kind = AnnotationKind.HIGHLIGHT.name,
        media = AnnotationMedia.EPUB.name,
        cfi = "epubcfi(/6/8!/4/2:10)",
        selectedText = "a quoted line",
        note = note,
        serverId = serverId,
        providerSource = BOOKORBIT_PROVIDER_SOURCE,
        syncDirty = false,
    )
}

private class FakeProviderAdapter(
    private val push: (List<ReaderAnnotation>) -> AnnotationsPushResult,
    private val remote: List<ReaderAnnotation>,
) : ProviderAdapter {
    override val source: BookSource = BookSource.BOOKORBIT
    override val annotationsAreAuthoritative: Boolean = true

    override suspend fun pushAnnotations(
        book: Book,
        annotations: List<ReaderAnnotation>,
    ): Result<AnnotationsPushResult> = Result.success(push(annotations))

    override suspend fun fetchAnnotations(
        book: Book,
        sinceUpdatedAt: Long?,
    ): Result<List<ReaderAnnotation>> = Result.success(remote)

    override suspend fun getLibraries(): Result<List<Library>> = Result.success(emptyList())

    override suspend fun getBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
    ): Result<List<Book>> = Result.success(emptyList())

    override suspend fun getContinueListening(): Result<List<Book>> = Result.success(emptyList())

    override suspend fun getContinueReading(): Result<List<Book>> = Result.success(emptyList())

    override suspend fun getRecentlyAdded(): Result<List<Book>> = Result.success(emptyList())

    override suspend fun getEbookDownloadUrl(bookId: String): String? = null

    override fun invalidateCaches() = Unit
}

private class FakeReaderAnnotationDao(vararg seed: ReaderAnnotation) : ReaderAnnotationDao {
    private val rows = LinkedHashMap<String, ReaderAnnotation>()

    init {
        seed.forEach { rows[it.id] = it }
    }

    fun ids(): List<String> = rows.keys.toList()

    override fun flowByBook(bookId: String): Flow<List<ReaderAnnotation>> = flowOf(rows.values.toList())

    override fun flowByBookAndKind(bookId: String, kind: String): Flow<List<ReaderAnnotation>> =
        flowOf(rows.values.filter { it.bookId == bookId && it.kind == kind })

    override fun flowAll(): Flow<List<ReaderAnnotation>> = flowOf(rows.values.toList())

    override fun search(pattern: String): Flow<List<ReaderAnnotation>> = flowOf(rows.values.toList())

    override suspend fun getByBook(bookId: String): List<ReaderAnnotation> =
        rows.values.filter { it.bookId == bookId && it.deletedAt == null }

    override suspend fun getById(id: String): ReaderAnnotation? = rows[id]

    override suspend fun getByServerId(serverId: String, providerSource: String): ReaderAnnotation? =
        rows.values.firstOrNull { it.serverId == serverId && it.providerSource == providerSource }

    override suspend fun getDirty(): List<ReaderAnnotation> = rows.values.filter { it.syncDirty }

    override suspend fun getDirtyForBook(bookId: String): List<ReaderAnnotation> =
        rows.values.filter { it.bookId == bookId && it.syncDirty }

    override suspend fun getDirtyForBookAndProvider(
        bookId: String,
        providerSource: String,
    ): List<ReaderAnnotation> =
        rows.values.filter { it.bookId == bookId && it.providerSource == providerSource && it.syncDirty }

    override suspend fun getDirtyBookIds(): List<String> =
        rows.values.filter { it.syncDirty }.map { it.bookId }.distinct()

    override suspend fun markClean(id: String, etag: String?, serverId: String?) {
        rows[id]?.let { rows[id] = it.copy(syncDirty = false, syncEtag = etag, serverId = serverId ?: it.serverId) }
    }

    override suspend fun moveBook(sourceBookId: String, targetBookId: String, now: Long) {
        rows.values.filter { it.bookId == sourceBookId }.forEach {
            rows[it.id] = it.copy(bookId = targetBookId, updatedAt = now, syncDirty = true)
        }
    }

    override suspend fun upsert(a: ReaderAnnotation) {
        rows[a.id] = a
    }

    override suspend fun upsertAll(list: List<ReaderAnnotation>) {
        list.forEach { rows[it.id] = it }
    }

    override suspend fun update(a: ReaderAnnotation) {
        rows[a.id] = a
    }

    override suspend fun softDelete(id: String, now: Long) {
        rows[id]?.let { rows[id] = it.copy(deletedAt = now, updatedAt = now, syncDirty = true) }
    }

    override suspend fun restore(id: String, now: Long) {
        rows[id]?.let { rows[id] = it.copy(deletedAt = null, updatedAt = now, syncDirty = true) }
    }

    override suspend fun delete(a: ReaderAnnotation) {
        rows.remove(a.id)
    }

    override suspend fun purge(id: String) {
        rows.remove(id)
    }

    override suspend fun purgeCleanProviderRows(bookId: String, providerSource: String) {
        rows.values.removeAll { it.isCleanServerBacked(bookId, providerSource) }
    }

    override suspend fun purgeCleanProviderRowsMissing(
        bookId: String,
        providerSource: String,
        serverIds: List<String>,
    ) {
        rows.values.removeAll { row ->
            row.isCleanServerBacked(bookId, providerSource) && serverIds.none { it == row.serverId }
        }
    }

    override suspend fun insert(a: ReaderAnnotation) {
        rows[a.id] = a
    }

    private fun ReaderAnnotation.isCleanServerBacked(bookId: String, providerSource: String): Boolean =
        this.bookId == bookId && this.providerSource == providerSource && !syncDirty && serverId != null
}
