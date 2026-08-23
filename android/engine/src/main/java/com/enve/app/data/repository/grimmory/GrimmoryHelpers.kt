package com.enve.app.data.repository.grimmory

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.Library
import com.enve.core.data.model.ReadStatus
import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.AudiobookInfoDto
import com.enve.app.data.remote.dto.AudiobookProgressDto
import com.enve.app.data.remote.dto.BookDetailDto
import com.enve.app.data.remote.dto.BookFileDto
import com.enve.app.data.remote.dto.BookSummaryDto
import com.enve.app.data.remote.dto.LibraryDto
import com.enve.core.data.util.normalizeFraction
import com.enve.core.data.util.parseServerDate
import com.enve.core.data.util.resolveAudiobookPositionSeconds
import com.enve.core.data.util.resolveDurationSeconds
import com.enve.core.data.util.runSuspendCatching
import com.enve.core.data.util.titleFromPrimaryFileName
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

internal const val GRIMMORY_COMPANION_AUDIOBOOK_ID_PREFIX = "grimmory-ab-"

internal fun String.grimmoryServerBookId(): String =
    if (startsWith(GRIMMORY_COMPANION_AUDIOBOOK_ID_PREFIX)) {
        drop(GRIMMORY_COMPANION_AUDIOBOOK_ID_PREFIX.length)
    } else {
        this
    }

internal fun grimmoryCompanionAudiobookId(bookId: String): String =
    if (bookId.startsWith(GRIMMORY_COMPANION_AUDIOBOOK_ID_PREFIX)) bookId
    else "$GRIMMORY_COMPANION_AUDIOBOOK_ID_PREFIX$bookId"

internal fun BookDetailDto.copyWithResolvedMediaType(): BookDetailDto = copy(primaryFileType = selectedFile()?.bookType ?: primaryFileType)

internal fun BookDetailDto.resolvedMediaType(): AppMediaType = (selectedFile()?.bookType ?: primaryFileType).toMediaType()

internal fun BookDetailDto.selectedFile(): BookFileDto? = primaryFile
    ?: files?.firstOrNull { it.isPrimaryFile() }
    ?: files?.firstOrNull()

internal fun BookFileDto.isPrimaryFile(): Boolean = isPrimary == true || primary == true

internal fun BookFileDto.resolvedType(): String? = bookType ?: fileExtension

private val audioTypes = setOf("AUDIOBOOK", "MP3", "M4A", "M4B", "FLAC", "OGG", "OPUS", "WAV", "AAC")
private val ebookTypes = setOf("EPUB", "PDF", "CBX", "CBR", "CBZ", "FB2", "MOBI", "AZW", "AZW3")

internal fun isGrimmoryAudioType(value: String?): Boolean =
    value?.uppercase()?.let { it in audioTypes || it.startsWith("AUDIO") } == true

internal fun isGrimmoryEbookType(value: String?): Boolean =
    value?.uppercase()?.let { it in ebookTypes } == true

internal fun BookSummaryDto.hasAudioFormat(): Boolean {
    val types = buildList {
        add(primaryFileType)
        add(primaryFile?.resolvedType())
        fileTypes?.let { addAll(it) }
        files?.mapNotNull { it.resolvedType() }?.let { addAll(it) }
        alternativeFormats?.mapNotNull { it.resolvedType() }?.let { addAll(it) }
    }
    return types.any(::isGrimmoryAudioType) ||
        audiobookCoverUpdatedOn != null ||
        thumbnailUrl?.contains("/audiobook-", ignoreCase = true) == true
}

internal fun BookSummaryDto.hasEbookFormat(): Boolean {
    val types = buildList {
        add(primaryFileType)
        add(primaryFile?.resolvedType())
        fileTypes?.let { addAll(it) }
        files?.mapNotNull { it.resolvedType() }?.let { addAll(it) }
        alternativeFormats?.mapNotNull { it.resolvedType() }?.let { addAll(it) }
    }
    return types.any(::isGrimmoryEbookType)
}

internal fun BookDetailDto.hasAudioFormat(): Boolean {
    val types = buildList {
        add(primaryFileType)
        add(primaryFile?.resolvedType())
        fileTypes?.let { addAll(it) }
        files?.mapNotNull { it.resolvedType() }?.let { addAll(it) }
    }
    return types.any(::isGrimmoryAudioType) ||
        audiobookProgress != null ||
        audiobookCoverUpdatedOn != null ||
        thumbnailUrl?.contains("/audiobook-", ignoreCase = true) == true
}

internal fun BookDetailDto.hasEbookFormat(): Boolean {
    val types = buildList {
        add(primaryFileType)
        add(primaryFile?.resolvedType())
        fileTypes?.let { addAll(it) }
        files?.mapNotNull { it.resolvedType() }?.let { addAll(it) }
    }
    return types.any(::isGrimmoryEbookType) || epubProgress != null || pdfProgress != null || cbxProgress != null
}

internal fun resolveGrimmoryTitle(defaultTitle: String, mediaType: AppMediaType, file: BookFileDto?): String {
    val fileTitle = titleFromPrimaryFileName(file?.fileName ?: file?.filePath ?: file?.fileSubPath)
    if (mediaType == AppMediaType.AUDIOBOOK) return fileTitle ?: defaultTitle.ifBlank { "Untitled" }
    return defaultTitle.ifBlank { fileTitle ?: "Untitled" }
}

internal fun BookDetailDto.hasEpubMediaOverlay(): Boolean {
    val fields = buildList {
        add(primaryFileType)
        fileTypes?.let { addAll(it) }
        files?.mapNotNull { it.bookType }?.let { addAll(it) }
    }.filterNotNull().joinToString("|") { it.lowercase() }

    val hasEpub = fields.contains("epub")
    val hasOverlaySignal =
        fields.contains("media-overlay") ||
        fields.contains("media_overlay") ||
        fields.contains("smil") ||
        fields.contains("epub3-mo") ||
        fields.contains("epub3mo") ||
        fields.contains("overlay")

    return hasEpub && hasOverlaySignal
}

internal fun String?.toMediaType(): AppMediaType {
    return when (this?.uppercase()) {
        "AUDIOBOOK", "MP3", "M4A", "M4B", "FLAC", "OGG", "OPUS", "WAV" -> AppMediaType.AUDIOBOOK
        else -> AppMediaType.EBOOK
    }
}

internal fun toReadStatus(readStatus: String?): ReadStatus {
    return when (readStatus?.uppercase()) {
        "IN_PROGRESS", "READING", "RE_READING" -> ReadStatus.IN_PROGRESS
        "ON_HOLD", "PAUSED", "PARTIALLY_READ" -> ReadStatus.ON_HOLD
        "COMPLETED", "READ" -> ReadStatus.COMPLETED
        else -> ReadStatus.UNREAD
    }
}

internal fun ReadStatus.toGrimmoryWireStatus(): String = when (this) {
    ReadStatus.UNREAD -> "UNREAD"
    ReadStatus.IN_PROGRESS -> "READING"
    ReadStatus.ON_HOLD -> "PAUSED"
    ReadStatus.COMPLETED -> "READ"
}

internal fun LibraryDto.toLibrary() = Library(
    id = id,
    name = name,
    bookCount = bookCount ?: 0,
)

internal fun BookSummaryDto.toBook(serverUrl: String, token: String? = null): Book {
    val effectivePrimaryFileType = primaryFile?.bookType ?: primaryFileType
    val mediaType = effectivePrimaryFileType.toMediaType()
    val resolvedTitle = if (mediaType == AppMediaType.AUDIOBOOK) {
        titleFromPrimaryFileName(primaryFileName) ?: resolveGrimmoryTitle(title, mediaType, primaryFile)
    } else {
        resolveGrimmoryTitle(title, mediaType, primaryFile)
    }
    val progressFraction = normalizeFraction(readProgress ?: epubProgress?.percentage)
    val normalizedReadStatus = readStatus?.uppercase()
    val hasAudio = mediaType == AppMediaType.AUDIOBOOK || hasAudioFormat()
    val hasEbook = mediaType == AppMediaType.EBOOK || hasEbookFormat()
    return Book(
        id = id,
        title = resolvedTitle,
        author = authors?.joinToString(", "),
        narrator = narrator,
        coverUrl = resolveCoverUrl(serverUrl, thumbnailUrl, id, mediaType, token),
        primaryFileType = effectivePrimaryFileType,
        seriesName = seriesName,
        seriesNumber = seriesNumber,
        libraryId = libraryId,
        libraryName = libraryName,
        addedOn = parseServerDate(addedOn),
        lastReadTime = parseServerDate(lastReadTime),
        readProgress = progressFraction,
        readStatus = toReadStatus(readStatus),
        serverReadStatus = normalizedReadStatus,
        isFinished = progressFraction >= 0.99f || normalizedReadStatus == "READ" || dateFinished != null,
        hideFromContinue = normalizedReadStatus == "ABANDONED",
        personalRating = personalRating?.div(2f),
        source = BookSource.GRIMMORY,
        mediaType = mediaType,
        duration = resolveDurationSeconds(
            durationSeconds = durationSeconds,
            durationValue = duration,
            durationMs = durationMs?.toLong(),
        ),
        epubProgress = normalizeFraction(epubProgress?.percentage).takeIf { it > 0f },
        epubLocator = epubProgress?.cfi,
        hasAudio = hasAudio,
        hasEbook = hasEbook,
        publishedDate = publishedDate,
        goodreadsRating = goodreadsRating,
        pageCount = pageCount,
        publisher = publisher,
        categories = categories.orEmpty(),
        language = language,
        isbn13 = isbn13 ?: isbn10,
    )
}

internal fun BookDetailDto.toBook(serverUrl: String, token: String? = null): Book {
    val mediaType = resolvedMediaType()
    val normalizedReadStatus = readStatus?.uppercase()
    val hasAudio = mediaType == AppMediaType.AUDIOBOOK || hasAudioFormat()
    val hasEbook = mediaType == AppMediaType.EBOOK || hasEbookFormat()
    return Book(
        id = id,
        title = resolveGrimmoryTitle(title, mediaType, selectedFile()),
        subtitle = subtitle,
        author = authors?.joinToString(", "),
        description = description,
        coverUrl = resolveCoverUrl(serverUrl, thumbnailUrl, id, mediaType, token),
        categories = categories ?: emptyList(),
        publisher = publisher,
        publishedDate = publishedDate,
        pageCount = pageCount,
        isbn13 = isbn13,
        language = language,
        goodreadsRating = goodreadsRating,
        libraryId = libraryId,
        libraryName = libraryName,
        seriesName = seriesName,
        seriesNumber = seriesNumber,
        addedOn = parseServerDate(addedOn),
        lastReadTime = parseServerDate(lastReadTime),
        readProgress = normalizeFraction(readProgress ?: epubProgress?.percentage ?: pdfProgress?.percentage ?: cbxProgress?.percentage),
        readStatus = toReadStatus(readStatus),
        serverReadStatus = normalizedReadStatus,
        personalRating = personalRating?.div(2f),
        primaryFileType = selectedFile()?.bookType ?: primaryFileType,
        shelves = shelves.orEmpty().map { it.name },
        epubProgress = normalizeFraction(readProgress ?: epubProgress?.percentage ?: pdfProgress?.percentage ?: cbxProgress?.percentage),
        epubLocator = epubProgress?.cfi ?: pdfProgress?.page?.let { "{\"page\":$it}" } ?: cbxProgress?.page?.let { "cbz-page:$it" },
        readAlongAvailable = hasEpubMediaOverlay(),
        currentTime = resolveAudiobookPositionSeconds(
            positionMs = grimmoryGlobalAudiobookPositionMs(audiobookProgress, null),
            percentage = audiobookProgress?.percentage,
            durationSeconds = durationSeconds,
            duration = duration,
        ),
        isFinished = normalizeFraction(readProgress ?: audiobookProgress?.percentage ?: epubProgress?.percentage ?: pdfProgress?.percentage ?: cbxProgress?.percentage) >= 0.99f || normalizedReadStatus == "READ" || dateFinished != null,
        hideFromContinue = normalizedReadStatus == "ABANDONED",
        source = BookSource.GRIMMORY,
        mediaType = mediaType,
        duration = resolveDurationSeconds(durationSeconds = durationSeconds, durationValue = duration, durationMs = durationMs?.toLong()),
        hasAudio = hasAudio,
        hasEbook = hasEbook,
    )
}

internal fun Book.companionAudiobook(serverUrl: String, token: String? = null): Book? {
    if (source != BookSource.GRIMMORY || mediaType != AppMediaType.EBOOK || !hasAudio) return null
    if (id.startsWith(GRIMMORY_COMPANION_AUDIOBOOK_ID_PREFIX)) return null
    val rawId = id.grimmoryServerBookId()
    return copy(
        id = grimmoryCompanionAudiobookId(rawId),
        mediaType = AppMediaType.AUDIOBOOK,
        primaryFileType = "AUDIOBOOK",
        coverUrl = resolveCoverUrl(serverUrl, null, rawId, AppMediaType.AUDIOBOOK, token),
        epubProgress = null,
        epubLocator = null,
        readAlongAvailable = false,
        hasAudio = true,
        hasEbook = true,
    )
}

data class GrimmoryWirePosition(val positionData: String, val positionHref: String?)

internal fun AudiobookInfoDto.trackStartsByIndex(): Map<Int, Long> {
    var running = 0L
    val out = HashMap<Int, Long>()
    tracks.orEmpty().forEachIndexed { position, track ->
        val start = track.cumulativeStartMs ?: running
        out[track.index.takeIf { it >= 0 } ?: position] = start
        running = start + (track.durationMs ?: 0L)
    }
    return out
}

internal fun grimmoryEncodeAudiobookPosition(
    globalMs: Long,
    multiFile: Boolean,
    trackStartsByIndex: Map<Int, Long>?,
): GrimmoryWirePosition {
    val g = globalMs.coerceAtLeast(0L)
    if (multiFile && !trackStartsByIndex.isNullOrEmpty()) {
        val (trackIndex, trackStart) = trackStartsByIndex.entries
            .filter { it.value <= g }
            .maxByOrNull { it.value }
            ?.toPair()
            ?: (0 to 0L)
        return GrimmoryWirePosition((g - trackStart).coerceAtLeast(0L).toString(), trackIndex.toString())
    }
    return GrimmoryWirePosition(g.toString(), null)
}

internal fun grimmoryGlobalAudiobookPositionMs(
    progress: AudiobookProgressDto?,
    trackStartsByIndex: Map<Int, Long>?,
): Long? {
    val ab = progress ?: return null
    val local = ab.positionMs ?: return null
    val trackIndex = ab.trackIndex
    if (trackIndex != null && trackIndex > 0) {
        val start = trackStartsByIndex?.get(trackIndex) ?: return null
        return start + local
    }
    return local
}

internal fun mergeListedAudiobook(
    book: Book,
    detail: BookDetailDto?,
    info: AudiobookInfoDto?,
    serverUrl: String? = null,
    token: String? = null,
): Book {
    var enriched = book

    if (detail != null) {
        val primaryFile = detail.selectedFile()
        val detailProgress = normalizeFraction(detail.audiobookProgress?.percentage)
        val detailDurationSeconds = resolveDurationSeconds(
            durationSeconds = detail.durationSeconds,
            durationValue = detail.duration,
            durationMs = detail.durationMs?.toLong(),
        )
        val detailCurrentTime = resolveAudiobookPositionSeconds(
            positionMs = grimmoryGlobalAudiobookPositionMs(detail.audiobookProgress, info?.trackStartsByIndex()),
            percentage = detailProgress,
            durationSeconds = detail.durationSeconds,
            duration = detail.duration,
        )

        val resolvedTitle = resolveGrimmoryTitle(detail.title, AppMediaType.AUDIOBOOK, primaryFile)
            .takeIf { it.isNotBlank() }
            ?: enriched.title

        enriched = enriched.copy(
            title = resolvedTitle,
            author = detail.authors?.joinToString(", ")?.takeIf { it.isNotBlank() } ?: enriched.author,
            description = detail.description ?: enriched.description,
            publisher = detail.publisher ?: enriched.publisher,
            libraryName = detail.libraryName ?: enriched.libraryName,
            coverUrl = serverUrl?.let { resolveCoverUrl(it, detail.thumbnailUrl, detail.id, AppMediaType.AUDIOBOOK, token) } ?: enriched.coverUrl,
            readProgress = detailProgress.takeIf { it > 0f } ?: enriched.readProgress,
            currentTime = detailCurrentTime.takeIf { it > 0L } ?: enriched.currentTime,
            duration = detailDurationSeconds.takeIf { it > 0 } ?: enriched.duration,
            isFinished = detailProgress >= 0.99f || detail.readStatus == "READ" || detail.dateFinished != null || enriched.isFinished,
            hideFromContinue = detail.readStatus == "ABANDONED" || enriched.hideFromContinue,
            addedOn = parseServerDate(detail.addedOn).takeIf { it > 0 } ?: enriched.addedOn,
            lastReadTime = parseServerDate(detail.lastReadTime).takeIf { it > 0 } ?: enriched.lastReadTime,
            hasAudio = enriched.hasAudio || detail.hasAudioFormat(),
            hasEbook = enriched.hasEbook || detail.hasEbookFormat(),
        )
    }

    if (info != null) {
        enriched = enriched.copy(
            author = info.author?.takeIf { it.isNotBlank() } ?: enriched.author,
            narrator = info.narrator?.takeIf { it.isNotBlank() } ?: enriched.narrator,
            duration = resolveDurationSeconds(durationSeconds = null, durationValue = null, durationMs = info.durationMs)
                .takeIf { it > 0 } ?: enriched.duration,
            codec = info.codec ?: enriched.codec,
            bitrate = info.bitrate ?: enriched.bitrate,
            sampleRate = info.sampleRate ?: enriched.sampleRate,
            channels = info.channels ?: enriched.channels,
            chapters = info.chapters.orEmpty().mapIndexed { index, chapter ->
                val startMs = chapter.startTimeMs.coerceAtLeast(0L)
                val endMsFromApi = chapter.endTimeMs.coerceAtLeast(0L)
                val durationMs = chapter.durationMs?.coerceAtLeast(0L)
                val resolvedEndMs = when {
                    endMsFromApi > startMs -> endMsFromApi
                    durationMs != null && durationMs > 0L -> startMs + durationMs
                    else -> startMs
                }
                Chapter(
                    index = chapter.index.takeIf { it >= 0 } ?: index,
                    title = chapter.title ?: "Chapter ${index + 1}",
                    startTime = startMs / 1000,
                    endTime = resolvedEndMs / 1000,
                )
            },
            audioTracks = info.tracks.orEmpty().mapIndexed { index, track ->
                AudioTrack(
                    index = track.index.takeIf { it >= 0 } ?: index,
                    fileName = track.fileName ?: "Track ${index + 1}",
                    title = track.title,
                    durationMs = track.durationMs ?: 0L,
                    fileSizeBytes = track.fileSizeBytes ?: 0L,
                    cumulativeStartMs = track.cumulativeStartMs ?: 0L,
                )
            },
        )
    }

    return enriched
}

internal fun mergeListedEbook(book: Book, detail: BookDetailDto, serverUrl: String, token: String? = null): Book {
    val rawProgress = normalizeFraction(detail.readProgress ?: detail.epubProgress?.percentage ?: detail.pdfProgress?.percentage ?: detail.cbxProgress?.percentage)
    val selectedFile = detail.selectedFile()
    val resolvedTitle = selectedFile?.fileName
        ?.substringBeforeLast('.')
        ?.trim()
        ?.takeIf { it.isNotBlank() }
        ?: detail.title
    return book.copy(
        title = resolvedTitle,
        subtitle = detail.subtitle ?: book.subtitle,
        author = detail.authors?.joinToString(", ")?.takeIf { it.isNotBlank() } ?: book.author,
        description = detail.description ?: book.description,
        publisher = detail.publisher ?: book.publisher,
        language = detail.language ?: book.language,
        pageCount = detail.pageCount ?: book.pageCount,
        categories = detail.categories ?: book.categories,
        primaryFileType = selectedFile?.bookType ?: detail.primaryFileType ?: book.primaryFileType,
        coverUrl = resolveCoverUrl(serverUrl, detail.thumbnailUrl, detail.id, AppMediaType.EBOOK, token),
        readProgress = rawProgress.takeIf { it > 0f } ?: book.readProgress,
        epubProgress = rawProgress.takeIf { it > 0f } ?: book.epubProgress,
        epubLocator = detail.epubProgress?.cfi ?: detail.pdfProgress?.page?.let { "{\"page\":$it}" } ?: detail.cbxProgress?.page?.let { "cbz-page:$it" } ?: book.epubLocator,
        isFinished = rawProgress >= 0.99f || detail.readStatus == "READ" || detail.dateFinished != null || book.isFinished,
        hideFromContinue = detail.readStatus == "ABANDONED" || book.hideFromContinue,
        addedOn = parseServerDate(detail.addedOn).takeIf { it > 0 } ?: book.addedOn,
        lastReadTime = parseServerDate(detail.lastReadTime).takeIf { it > 0 } ?: book.lastReadTime,
        libraryName = detail.libraryName ?: book.libraryName,
        hasAudio = book.hasAudio || detail.hasAudioFormat(),
        hasEbook = book.hasEbook || detail.hasEbookFormat(),
    )
}

internal suspend fun resolveAmbiguousAudiobookTitles(
    books: List<Book>,
    api: GrimmoryApi,
    audiobookTitleOverrideCache: MutableMap<String, String>,
    audiobookDurationOverrideCache: MutableMap<String, Long> = mutableMapOf(),
): List<Book> = coroutineScope {
    if (books.isEmpty()) return@coroutineScope books

    val audiobookBooks = books.filter { it.mediaType == AppMediaType.AUDIOBOOK }
    if (audiobookBooks.isEmpty()) return@coroutineScope books

    val duplicateTitleKeys = audiobookBooks
        .groupBy { it.title.trim().lowercase() }
        .filter { it.value.size > 1 }
        .keys

    val candidates = audiobookBooks
        .filter { book ->
            val titleKey = book.title.trim().lowercase()
            val needsTitle = book.title.isBlank() ||
                duplicateTitleKeys.contains(titleKey) ||
                (book.seriesName?.trim()?.equals(book.title.trim(), ignoreCase = true) == true)
            val needsDuration = book.duration <= 0L
            needsTitle || needsDuration
        }
        .distinctBy { it.id }
        .take(40)

    if (candidates.isEmpty()) return@coroutineScope books

    data class ResolvedFields(val title: String?, val durationSeconds: Long?)

    val semaphore = Semaphore(6)
    val resolved = candidates.map { book ->
        async {
            val cachedTitle = audiobookTitleOverrideCache[book.id]
            val cachedDuration = audiobookDurationOverrideCache[book.id]
            if (!cachedTitle.isNullOrBlank() && cachedDuration != null && cachedDuration > 0L) {
                return@async book.id to ResolvedFields(cachedTitle, cachedDuration)
            }

            semaphore.withPermit {
                val needsTitle = cachedTitle.isNullOrBlank()
                val needsDuration = cachedDuration == null || cachedDuration <= 0L
                val rawBookId = book.id.grimmoryServerBookId()

                val detail = if (needsTitle) {
                    runSuspendCatching { api.getBookDetail(rawBookId) }.getOrNull()?.body()
                } else null

                val resolvedTitle = cachedTitle?.takeIf { it.isNotBlank() }
                    ?: detail
                        ?.let { resolveGrimmoryTitle(it.title, AppMediaType.AUDIOBOOK, it.selectedFile()) }
                        ?.takeIf { it.isNotBlank() }

                val durationFromDetail = detail?.let {
                    resolveDurationSeconds(
                        durationSeconds = it.durationSeconds,
                        durationValue = it.duration,
                        durationMs = it.durationMs?.toLong(),
                    )
                }?.takeIf { it > 0L }
                val resolvedDurationSeconds = when {
                    !needsDuration -> cachedDuration
                    durationFromDetail != null -> durationFromDetail
                    else -> {
                        val info = runSuspendCatching { api.getAudiobookInfo(rawBookId) }.getOrNull()?.body()
                        info?.durationMs
                            ?.let { resolveDurationSeconds(durationSeconds = null, durationValue = null, durationMs = it) }
                            ?.takeIf { it > 0L }
                    }
                }

                if (!resolvedTitle.isNullOrBlank()) {
                    audiobookTitleOverrideCache[book.id] = resolvedTitle
                }
                if (resolvedDurationSeconds != null && resolvedDurationSeconds > 0L) {
                    audiobookDurationOverrideCache[book.id] = resolvedDurationSeconds
                }
                if (!resolvedTitle.isNullOrBlank() || (resolvedDurationSeconds != null && resolvedDurationSeconds > 0L)) {
                    book.id to ResolvedFields(resolvedTitle, resolvedDurationSeconds)
                } else {
                    null
                }
            }
        }
    }.awaitAll().filterNotNull().toMap()

    if (resolved.isEmpty()) return@coroutineScope books
    books.map { book ->
        val fields = resolved[book.id] ?: return@map book
        val newTitle = fields.title?.takeIf { it.isNotBlank() }
        val newDuration = fields.durationSeconds?.takeIf { it > 0L }
        when {
            newTitle != null && newDuration != null -> book.copy(title = newTitle, duration = newDuration)
            newTitle != null -> book.copy(title = newTitle)
            newDuration != null -> book.copy(duration = newDuration)
            else -> book
        }
    }
}

internal fun rewriteLegacyCoverPath(path: String, mediaType: AppMediaType): String {
    if (!path.startsWith("/api/books/")) return path
    val withoutPrefix = path.removePrefix("/api/books/")
    val slashIdx = withoutPrefix.indexOf('/')
    if (slashIdx < 0) return path
    val bookId = withoutPrefix.substring(0, slashIdx)
    val suffix = withoutPrefix.substring(slashIdx)
    return when (suffix) {
        "/cover" -> when (mediaType) {
            AppMediaType.AUDIOBOOK -> "/api/v1/media/book/$bookId/audiobook-thumbnail"
            else -> "/api/v1/media/book/$bookId/cover"
        }
        "/thumbnail" -> when (mediaType) {
            AppMediaType.AUDIOBOOK -> "/api/v1/media/book/$bookId/audiobook-thumbnail"
            else -> "/api/v1/media/book/$bookId/thumbnail"
        }
        "/audiobook-cover" -> "/api/v1/media/book/$bookId/audiobook-cover"
        "/audiobook-thumbnail" -> "/api/v1/media/book/$bookId/audiobook-thumbnail"
        else -> "/api/v1/media/book/$bookId$suffix"
    }
}

@Suppress("UNUSED_PARAMETER")
internal fun resolveCoverUrl(serverUrl: String, path: String?, bookId: String, mediaType: AppMediaType, token: String? = null): String {
    val resolvedPath = when {
        path.isNullOrBlank() -> fallbackCoverPath(bookId, mediaType)
        path.startsWith("http") -> return rewriteLegacyCoverUrl(path, mediaType)
        path.startsWith("/api/books/") -> rewriteLegacyCoverPath(path, mediaType)
        else -> path
    }

    return "${serverUrl.trimEnd('/')}${if (resolvedPath.startsWith('/')) resolvedPath else "/$resolvedPath"}"
}

internal fun rewriteLegacyCoverUrl(url: String, mediaType: AppMediaType): String {
    val slashAfterHost = url.indexOf('/', url.indexOf("//") + 2).takeIf { it >= 0 } ?: return url
    val path = url.substring(slashAfterHost)
    val rewritten = rewriteLegacyCoverPath(path, mediaType)
    return if (rewritten != path) url.substring(0, slashAfterHost) + rewritten else url
}

internal fun fallbackCoverPath(bookId: String, mediaType: AppMediaType): String {
    return when (mediaType) {
        AppMediaType.AUDIOBOOK -> "/api/v1/media/book/$bookId/audiobook-thumbnail"
        else -> "/api/v1/media/book/$bookId/cover"
    }
}
