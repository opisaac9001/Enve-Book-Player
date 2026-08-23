package com.enve.app.data.provider

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.Library
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.ReaderAnnotation
import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.*
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.app.data.repository.grimmory.grimmoryServerBookId
import com.enve.core.data.sync.AcceptedAnnotation
import com.enve.core.data.sync.AnnotationsPushResult
import com.enve.core.data.sync.RejectedAnnotation
import com.enve.core.data.sync.SyncCapability
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.ProviderEbookResource
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.provider.synthesizeChaptersFromTracks
import com.enve.core.data.util.runSuspendCatching
import com.enve.core.reader.EpubBridgeCheckpointCodec
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import kotlinx.coroutines.CancellationException
import org.json.JSONObject
import javax.inject.Inject
import javax.inject.Singleton

private enum class GrimmoryArtifactKind(val prefix: String) {
    ANNOTATION("annotation"),
    NOTE("note"),
    BOOKMARK("bookmark"),
}

private data class GrimmoryArtifactId(
    val kind: GrimmoryArtifactKind,
    val value: Long,
)

private fun grimmoryArtifactId(kind: GrimmoryArtifactKind, value: Long): String =
    "${kind.prefix}:$value"

private fun parseGrimmoryArtifactId(value: String): GrimmoryArtifactId? {
    val raw = value.trim()
    val separator = raw.indexOf(':')
    if (separator < 0) {
        return raw.toLongOrNull()?.let {
            GrimmoryArtifactId(GrimmoryArtifactKind.ANNOTATION, it)
        }
    }
    val kind = GrimmoryArtifactKind.entries.firstOrNull {
        it.prefix == raw.substring(0, separator)
    } ?: return null
    val id = raw.substring(separator + 1).toLongOrNull() ?: return null
    return GrimmoryArtifactId(kind, id)
}

private fun ReaderAnnotation.grimmoryCfi(): String? {
    cfi?.trim()?.takeIf { it.startsWith("epubcfi(") }?.let { return it }
    return EpubBridgeCheckpointCodec.cfi(locatorJson)
}

private fun grimmoryLocatorJson(cfi: String?, totalProgression: Double?): String? {
    val exact = cfi?.trim()?.takeIf { it.startsWith("epubcfi(") } ?: return null
    val locations = JSONObject().put("cfi", exact)
    totalProgression?.takeIf(Double::isFinite)?.coerceIn(0.0, 1.0)?.let {
        locations.put("totalProgression", it)
    }
    return JSONObject()
        .put("href", "")
        .put("type", "application/xhtml+xml")
        .put("locations", locations)
        .toString()
}

private fun grimmoryTimestamp(vararg values: String?): Long {
    values.forEach { value ->
        val raw = value?.trim()?.takeIf(String::isNotBlank) ?: return@forEach
        runCatching { Instant.parse(raw).toEpochMilli() }.getOrNull()?.let { return it }
        runCatching { OffsetDateTime.parse(raw).toInstant().toEpochMilli() }
            .getOrNull()?.let { return it }
        runCatching { LocalDateTime.parse(raw).toInstant(ZoneOffset.UTC).toEpochMilli() }
            .getOrNull()?.let { return it }
    }
    return System.currentTimeMillis()
}

private fun GrimmoryAnnotationDto.toReaderAnnotation(bookId: String): ReaderAnnotation {
    val created = grimmoryTimestamp(createdAt)
    val updated = grimmoryTimestamp(updatedAt, createdAt)
    return ReaderAnnotation(
        id = "grimmory-annotation-$id",
        bookId = bookId,
        kind = AnnotationKind.HIGHLIGHT.name,
        media = AnnotationMedia.EPUB.name,
        style = style?.uppercase()?.let(AnnotationStyle::parse)?.name
            ?: AnnotationStyle.HIGHLIGHT.name,
        colorHex = color ?: "#FFF59D",
        locatorJson = grimmoryLocatorJson(cfi, null),
        cfi = cfi,
        selectedText = text.orEmpty(),
        note = note.orEmpty(),
        chapterId = chapterTitle,
        createdAt = created,
        updatedAt = updated,
        serverId = grimmoryArtifactId(GrimmoryArtifactKind.ANNOTATION, id),
        providerSource = "grimmory",
        syncDirty = false,
        syncEtag = updatedAt,
    )
}

private fun GrimmoryBookNoteDto.toReaderAnnotation(bookId: String): ReaderAnnotation {
    val created = grimmoryTimestamp(createdAt)
    val updated = grimmoryTimestamp(updatedAt, createdAt)
    return ReaderAnnotation(
        id = "grimmory-note-$id",
        bookId = bookId,
        kind = AnnotationKind.NOTE.name,
        media = AnnotationMedia.EPUB.name,
        style = AnnotationStyle.NONE.name,
        colorHex = color ?: "#FFF59D",
        locatorJson = grimmoryLocatorJson(cfi, null),
        cfi = cfi,
        selectedText = selectedText.orEmpty(),
        note = noteContent.orEmpty(),
        chapterId = chapterTitle,
        createdAt = created,
        updatedAt = updated,
        serverId = grimmoryArtifactId(GrimmoryArtifactKind.NOTE, id),
        providerSource = "grimmory",
        syncDirty = false,
        syncEtag = updatedAt,
    )
}

private fun GrimmoryBookmarkDto.toReaderAnnotation(bookId: String): ReaderAnnotation {
    val remoteId = id.toLong()
    val created = grimmoryTimestamp(createdAt)
    val updated = grimmoryTimestamp(updatedAt, createdAt)
    return ReaderAnnotation(
        id = "grimmory-bookmark-$id",
        bookId = bookId,
        kind = AnnotationKind.BOOKMARK.name,
        media = AnnotationMedia.EPUB.name,
        style = AnnotationStyle.NONE.name,
        colorHex = color ?: "#FACC15",
        locatorJson = grimmoryLocatorJson(cfi, null),
        cfi = cfi,
        selectedText = title.orEmpty(),
        note = notes.orEmpty(),
        createdAt = created,
        updatedAt = updated,
        serverId = grimmoryArtifactId(GrimmoryArtifactKind.BOOKMARK, remoteId),
        providerSource = "grimmory",
        syncDirty = false,
        syncEtag = updatedAt,
    )
}

@Singleton
class GrimmoryProviderAdapter @Inject constructor(
    private val repository: GrimmoryRepository,
    private val api: GrimmoryApi,
) : ProviderAdapter {
    override val source: BookSource = BookSource.GRIMMORY
    override val syncCapability: SyncCapability = SyncCapability.FULL
    override val supportsPersonalRating: Boolean = true

    override suspend fun getLibraries(): Result<List<Library>> =
        repository.getLibrariesForSource(source)

    override suspend fun getBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
    ): Result<List<Book>> = repository.getBooksForSource(
        source = source,
        libraryId = libraryId,
        page = page,
        size = size,
        sort = sort,
        dir = dir,
    )

    override suspend fun getContinueListening(): Result<List<Book>> =
        repository.getContinueListeningForSource(source)

    override suspend fun getContinueReading(): Result<List<Book>> =
        repository.getContinueReadingForSource(source)

    override suspend fun getRecentlyAdded(): Result<List<Book>> =
        repository.getRecentlyAddedForSource(source)

    override suspend fun getEbookDownloadUrl(bookId: String): String? =
        repository.getEbookDownloadUrl(bookId)

    override suspend fun getEbookResource(bookId: String): ProviderEbookResource =
        repository.getEbookResource(bookId)

    override suspend fun updateBookStatus(bookId: String, status: String): Result<Unit> =
        repository.updateBookStatus(bookId, status)

    override suspend fun updatePersonalRating(bookId: String, rating: Int): Result<Unit> =
        repository.updateBookRating(bookId, rating)

    override suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = runSuspendCatching {
        val info = repository.getAudiobookInfo(book.id).getOrThrow()
        val chapters = info.chapters?.mapIndexed { index, chapter ->
            Chapter(
                index = chapter.index.takeIf { it >= 0 } ?: index,
                title = chapter.title ?: "Chapter ${index + 1}",
                startTime = chapter.startTimeMs / 1000,
                endTime = chapter.endTimeMs / 1000,
            )
        }.orEmpty()
        val tracks = info.tracks?.mapIndexed { index, track ->
            com.enve.core.data.model.AudioTrack(
                index = track.index.takeIf { it >= 0 } ?: index,
                fileName = track.fileName ?: track.title ?: "Track ${index + 1}",
                title = track.title ?: track.fileName,
                durationMs = track.durationMs ?: 0L,
                fileSizeBytes = track.fileSizeBytes ?: 0L,
                cumulativeStartMs = track.cumulativeStartMs ?: 0L,
                contentUrl = repository.getTrackStreamUrl(book.id, track.index.takeIf { it >= 0 } ?: index),
            )
        }.orEmpty().ifEmpty {
            listOf(
                com.enve.core.data.model.AudioTrack(
                    index = 0,
                    fileName = book.title,
                    title = book.title,
                    durationMs = (info.durationMs ?: (book.duration * 1000L)),
                    contentUrl = repository.getStreamUrl(book.id),
                )
            )
        }
        ProviderPlaybackSession(
            sessionId = "grimmory-${book.id}",
            audioTracks = tracks,
            chapters = chapters.ifEmpty { synthesizeChaptersFromTracks(tracks, book.duration) },
        )
    }

    override suspend fun fetchChapters(book: Book): Result<List<Chapter>> =
        startPlaybackSession(book).mapCatching { session ->
            session.chapters.ifEmpty { synthesizeChaptersFromTracks(session.audioTracks, book.duration) }
        }

    override suspend fun fetchAudiobookNarrator(book: Book): Result<String?> = runSuspendCatching {
        repository.getBookDetail(book.id).getOrThrow().narrator
    }

    override suspend fun fetchAudiobookProgress(book: Book): Result<SyncSnapshot?> =
        repository.fetchAudiobookProgress(book)

    override suspend fun fetchEbookProgress(book: Book): Result<SyncSnapshot?> =
        repository.fetchEbookProgress(book)

    override suspend fun syncEbookProgress(
        bookId: String,
        percentage: Float,
        locator: String?,
        page: Int?,
        pageCount: Int?,
    ): Result<Unit> = repository.syncEbookProgress(bookId, percentage, locator)

    override suspend fun syncAudiobookProgress(
        book: Book,
        currentTimeSec: Long,
        progressFraction: Float,
    ): Result<Unit> = repository.syncAudiobookProgress(book, currentTimeSec, progressFraction)

    override suspend fun pushAnnotations(
        book: Book,
        annotations: List<ReaderAnnotation>,
    ): Result<AnnotationsPushResult> {
        return try {
            if (annotations.isEmpty()) return Result.success(AnnotationsPushResult())
            val bookId = book.id.grimmoryServerBookId().toLongOrNull()
                ?: return Result.failure(IllegalArgumentException("Grimmory book id is not numeric"))
            val accepted = mutableListOf<AcceptedAnnotation>()
            val rejected = mutableListOf<RejectedAnnotation>()

            annotations.forEach { annotation ->
                val remoteId = annotation.serverId?.let(::parseGrimmoryArtifactId)
                if (annotation.deletedAt != null) {
                    if (remoteId == null && annotation.serverId != null) {
                        rejected += RejectedAnnotation(annotation.id, "Invalid Grimmory artifact id")
                        return@forEach
                    }
                    if (remoteId != null) {
                        val response = when (remoteId.kind) {
                            GrimmoryArtifactKind.ANNOTATION -> api.deleteAnnotation(remoteId.value)
                            GrimmoryArtifactKind.NOTE -> api.deleteBookNote(remoteId.value)
                            GrimmoryArtifactKind.BOOKMARK -> api.deleteBookmark(remoteId.value)
                        }
                        if (!response.isSuccessful && response.code() != 404) {
                            rejected += RejectedAnnotation(annotation.id, "HTTP ${response.code()}")
                            return@forEach
                        }
                    }
                    accepted += AcceptedAnnotation(annotation.id, annotation.serverId)
                    return@forEach
                }

                val cfi = annotation.grimmoryCfi()
                if (cfi == null) {
                    rejected += RejectedAnnotation(
                        annotation.id,
                        "Grimmory requires an EPUB CFI",
                    )
                    return@forEach
                }

                when (AnnotationKind.parse(annotation.kind)) {
                    AnnotationKind.HIGHLIGHT -> {
                        val selectedText = annotation.selectedText.ifBlank { annotation.note }
                        if (selectedText.isBlank()) {
                            rejected += RejectedAnnotation(
                                annotation.id,
                                "Grimmory annotation text is empty",
                            )
                            return@forEach
                        }
                        val response = if (remoteId == null) {
                            api.createAnnotation(
                                GrimmoryAnnotationCreateRequest(
                                    bookId = bookId,
                                    cfi = cfi,
                                    text = selectedText,
                                    color = annotation.colorHex,
                                    style = AnnotationStyle.parse(annotation.style).name.lowercase(),
                                    note = annotation.note.takeIf(String::isNotBlank),
                                    chapterTitle = annotation.chapterId,
                                ),
                            )
                        } else if (remoteId.kind == GrimmoryArtifactKind.ANNOTATION) {
                            api.updateAnnotation(
                                remoteId.value,
                                GrimmoryAnnotationUpdateRequest(
                                    color = annotation.colorHex,
                                    style = AnnotationStyle.parse(annotation.style).name.lowercase(),
                                    note = annotation.note.takeIf(String::isNotBlank),
                                ),
                            )
                        } else {
                            rejected += RejectedAnnotation(annotation.id, "Artifact kind changed")
                            return@forEach
                        }
                        val body = response.body() ?: if (
                            remoteId == null && response.code() == 409
                        ) {
                            api.getAnnotationsForBook(bookId.toString())
                                .takeIf { it.isSuccessful }
                                ?.body()
                                .orEmpty()
                                .firstOrNull {
                                    it.cfi == cfi && it.text == selectedText
                                }
                        } else {
                            null
                        }
                        if (body == null) {
                            rejected += RejectedAnnotation(annotation.id, "HTTP ${response.code()}")
                        } else {
                            accepted += AcceptedAnnotation(
                                id = annotation.id,
                                serverId = grimmoryArtifactId(
                                    GrimmoryArtifactKind.ANNOTATION,
                                    body.id,
                                ),
                                etag = body.updatedAt,
                            )
                        }
                    }

                    AnnotationKind.NOTE -> {
                        if (annotation.note.isBlank()) {
                            rejected += RejectedAnnotation(annotation.id, "Grimmory note is empty")
                            return@forEach
                        }
                        val response = if (remoteId == null) {
                            api.createBookNote(
                                GrimmoryBookNoteCreateRequest(
                                    bookId = bookId,
                                    cfi = cfi,
                                    selectedText = annotation.selectedText,
                                    noteContent = annotation.note,
                                    color = annotation.colorHex,
                                    chapterTitle = annotation.chapterId,
                                ),
                            )
                        } else if (remoteId.kind == GrimmoryArtifactKind.NOTE) {
                            api.updateBookNote(
                                remoteId.value,
                                GrimmoryBookNoteUpdateRequest(
                                    noteContent = annotation.note,
                                    color = annotation.colorHex,
                                    chapterTitle = annotation.chapterId,
                                ),
                            )
                        } else {
                            rejected += RejectedAnnotation(annotation.id, "Artifact kind changed")
                            return@forEach
                        }
                        val body = response.body()
                        if (!response.isSuccessful || body == null) {
                            rejected += RejectedAnnotation(annotation.id, "HTTP ${response.code()}")
                        } else {
                            accepted += AcceptedAnnotation(
                                id = annotation.id,
                                serverId = grimmoryArtifactId(GrimmoryArtifactKind.NOTE, body.id),
                                etag = body.updatedAt,
                            )
                        }
                    }

                    AnnotationKind.BOOKMARK -> {
                        val response = if (remoteId == null) {
                            api.createBookmark(
                                GrimmoryBookmarkCreateRequest(
                                    bookId = bookId.toInt(),
                                    title = annotation.selectedText.takeIf(String::isNotBlank),
                                    notes = annotation.note.takeIf(String::isNotBlank),
                                    cfi = cfi,
                                ),
                            )
                        } else if (remoteId.kind == GrimmoryArtifactKind.BOOKMARK) {
                            api.updateBookmark(
                                remoteId.value,
                                GrimmoryBookmarkUpdateRequest(
                                    title = annotation.selectedText.takeIf(String::isNotBlank),
                                    cfi = cfi,
                                    notes = annotation.note.takeIf(String::isNotBlank),
                                ),
                            )
                        } else {
                            rejected += RejectedAnnotation(annotation.id, "Artifact kind changed")
                            return@forEach
                        }
                        val body = response.body()
                        val bodyId = body?.id?.toLongOrNull()
                        if (!response.isSuccessful || bodyId == null) {
                            rejected += RejectedAnnotation(annotation.id, "HTTP ${response.code()}")
                        } else {
                            accepted += AcceptedAnnotation(
                                id = annotation.id,
                                serverId = grimmoryArtifactId(
                                    GrimmoryArtifactKind.BOOKMARK,
                                    bodyId,
                                ),
                                etag = body.updatedAt,
                            )
                        }
                    }
                }
            }
            Result.success(AnnotationsPushResult(accepted = accepted, rejected = rejected))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Result.failure(error)
        }
    }

    override suspend fun fetchAnnotations(
        book: Book,
        sinceUpdatedAt: Long?,
    ): Result<List<ReaderAnnotation>> {
        return try {
            val bookId = book.id.grimmoryServerBookId()
            val annotations = api.getAnnotationsForBook(bookId)
            val notes = api.getBookNotesForBook(bookId)
            val bookmarks = api.getBookmarksForBook(bookId)
            for (response in listOf(annotations, notes, bookmarks)) {
                if (!response.isSuccessful && response.code() != 404) {
                    error("fetchAnnotations HTTP ${response.code()}")
                }
            }
            Result.success(
                annotations.body().orEmpty().map { it.toReaderAnnotation(book.id) } +
                    notes.body().orEmpty().map { it.toReaderAnnotation(book.id) } +
                    bookmarks.body().orEmpty().map { it.toReaderAnnotation(book.id) },
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Result.failure(error)
        }
    }

    override suspend fun deleteRemoteAnnotation(
        book: Book,
        serverId: String,
    ): Result<Unit> {
        return try {
            val remoteId = parseGrimmoryArtifactId(serverId)
                ?: return Result.failure(IllegalArgumentException("Invalid Grimmory artifact id"))
            val response = when (remoteId.kind) {
                GrimmoryArtifactKind.ANNOTATION -> api.deleteAnnotation(remoteId.value)
                GrimmoryArtifactKind.NOTE -> api.deleteBookNote(remoteId.value)
                GrimmoryArtifactKind.BOOKMARK -> api.deleteBookmark(remoteId.value)
            }
            if (!response.isSuccessful && response.code() != 404) {
                error("deleteAnnotation HTTP ${response.code()}")
            }
            Result.success(Unit)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Result.failure(error)
        }
    }

    override fun invalidateCaches() {
        repository.invalidateListCaches()
    }

    override suspend fun getSeries(): Result<List<com.enve.core.data.remote.dto.SeriesSummaryDto>> =
        repository.getSeries()

    override suspend fun getAuthors(): Result<List<com.enve.core.data.remote.dto.AuthorSummaryDto>> =
        repository.getAuthors()

    override suspend fun getShelves(): Result<List<com.enve.core.data.model.Shelf>> =
        repository.getShelves()

    override suspend fun getShelfBooks(shelfId: String): Result<List<Book>> =
        repository.getShelfBooks(shelfId)
}
