package com.enve.app.data.kavita

import com.enve.app.data.remote.dto.KavitaChapterDto
import com.enve.app.data.remote.dto.KavitaSeriesDto
import com.enve.app.data.remote.dto.KavitaVolumeDto
import com.enve.app.data.repository.kavitaReaderFormat
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ReadStatus
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset

private const val LOOSE_LEAF_NUMBER = -100_000f
private const val SPECIAL_VOLUME_NUMBER = 100_000f

internal sealed interface KavitaBookRef {
    val seriesId: Int

    data class Legacy(override val seriesId: Int) : KavitaBookRef

    data class Issue(override val seriesId: Int, val volumeId: Int, val chapterId: Int) : KavitaBookRef
}

internal data class KavitaIssue(
    val seriesId: Int,
    val volume: KavitaVolumeDto,
    val chapter: KavitaChapterDto,
)

internal fun kavitaBookRef(bookId: String): KavitaBookRef? {
    val parts = bookId.split(':').map { it.toIntOrNull() ?: return null }
    if (parts.any { it <= 0 }) return null
    return when (parts.size) {
        1 -> KavitaBookRef.Legacy(parts[0])
        3 -> KavitaBookRef.Issue(parts[0], parts[1], parts[2])
        else -> null
    }
}

internal fun kavitaIssueBookId(seriesId: Int, volumeId: Int, chapterId: Int): String = "$seriesId:$volumeId:$chapterId"

internal fun kavitaLegacyChapterCandidate(volumes: List<KavitaVolumeDto>): Int? =
    volumes.firstOrNull { it.chapters.isNotEmpty() }?.chapters?.first()?.id

internal fun resolveKavitaIssue(ref: KavitaBookRef, volumes: List<KavitaVolumeDto>, legacyChapterId: Int?): KavitaIssue {
    val match = when (ref) {
        is KavitaBookRef.Legacy -> {
            val chapterId = legacyChapterId ?: error("Kavita series ${ref.seriesId} has no chapters")
            volumes.firstNotNullOfOrNull { volume ->
                volume.chapters.firstOrNull { it.id == chapterId }?.let { volume to it }
            }
        }
        is KavitaBookRef.Issue -> volumes.firstOrNull { it.id == ref.volumeId }
            ?.let { volume -> volume.chapters.firstOrNull { it.id == ref.chapterId }?.let { volume to it } }
    } ?: error("Kavita issue is no longer available in series ${ref.seriesId}")
    check(match.second.pages > 0) { "Kavita issue has no readable pages" }
    return KavitaIssue(ref.seriesId, match.first, match.second)
}

internal fun kavitaIssueFormat(chapter: KavitaChapterDto, seriesFormat: Int): Int =
    chapter.format ?: chapter.files.firstOrNull()?.format ?: seriesFormat

internal fun expandKavitaSeries(
    series: KavitaSeriesDto,
    volumes: List<KavitaVolumeDto>,
    legacyChapterId: Int?,
    serverUrl: String,
    fallbackLibraryId: String?,
): List<Book> {
    val issues = volumes
        .flatMap { volume -> volume.chapters.filter { it.pages > 0 }.map { KavitaIssue(series.id, volume, it) } }
        .sortedWith(
            compareBy<KavitaIssue> { it.readingGroup }
                .thenBy { it.volume.minNumber }
                .thenBy { it.chapter.sortOrder }
                .thenBy { it.chapter.minNumber }
                .thenBy { it.chapter.id },
        )
    if (issues.isEmpty()) return emptyList()
    val seriesName = series.name.orEmpty()
    val single = issues.size == 1
    val sequence = kavitaSequenceNumbers(issues)
    val base = serverUrl.trimEnd('/')
    return issues.mapIndexed { index, issue ->
        val chapter = issue.chapter
        Book(
            id = if (chapter.id == legacyChapterId) series.id.toString() else kavitaIssueBookId(series.id, issue.volume.id, chapter.id),
            title = if (single) seriesName else issue.title(seriesName, index),
            coverUrl = "$base/api/Image/chapter-cover?chapterId=${chapter.id}",
            source = BookSource.KAVITA,
            mediaType = AppMediaType.EBOOK,
            seriesName = seriesName.takeUnless { single || it.isBlank() },
            seriesNumber = sequence[index].takeUnless { single },
            primaryFileType = kavitaReaderFormat(kavitaIssueFormat(chapter, series.format)),
            libraryId = series.libraryId?.toString() ?: fallbackLibraryId,
            pageCount = chapter.pages,
            readProgress = (chapter.pagesRead.toFloat() / chapter.pages).coerceIn(0f, 1f),
            isFinished = chapter.pagesRead >= chapter.pages,
            readStatus = when {
                chapter.pagesRead >= chapter.pages -> ReadStatus.COMPLETED
                chapter.pagesRead > 0 -> ReadStatus.IN_PROGRESS
                else -> ReadStatus.UNREAD
            },
            addedOn = epochMs(chapter.createdUtc) ?: epochMs(series.created) ?: 0L,
            lastReadTime = epochMs(chapter.lastReadingProgressUtc)?.takeIf { chapter.pagesRead > 0 } ?: 0L,
        )
    }
}

private val KavitaVolumeDto.isLooseLeaf: Boolean get() = minNumber == LOOSE_LEAF_NUMBER

private val KavitaVolumeDto.isSpecialVolume: Boolean get() = minNumber == SPECIAL_VOLUME_NUMBER

private val KavitaChapterDto.isDefault: Boolean get() = minNumber == LOOSE_LEAF_NUMBER

private val KavitaIssue.isSpecial: Boolean get() = chapter.isSpecial || volume.isSpecialVolume

private val KavitaIssue.readingGroup: Int
    get() = when {
        isSpecial -> 2
        volume.isLooseLeaf -> 1
        else -> 0
    }

private val KavitaIssue.numberedLabel: String?
    get() {
        if (isSpecial) return null
        val volumePart = volume.takeUnless { it.isLooseLeaf }
            ?.let { "Vol. ${it.name?.takeIf(String::isNotBlank) ?: it.minNumber.display()}" }
        val chapterPart = chapter.takeUnless { it.isDefault }
            ?.let { "#${it.range?.takeIf(String::isNotBlank) ?: it.minNumber.display()}" }
        return listOfNotNull(volumePart, chapterPart).joinToString(" ").ifBlank { null }
    }

private fun KavitaIssue.title(seriesName: String, index: Int): String {
    val label = numberedLabel
    val name = chapter.titleName?.takeIf(String::isNotBlank)
        ?: chapter.title?.takeIf { label == null && it.isNotBlank() }
    val heading = listOf(seriesName, label ?: if (name == null) "#${index + 1}" else null)
        .filterNot { it.isNullOrBlank() }
        .joinToString(" ")
    return listOfNotNull(heading.ifBlank { null }, name).joinToString(": ")
}

private fun kavitaSequenceNumbers(issues: List<KavitaIssue>): List<String?> {
    val numbers = issues.map { issue ->
        when {
            issue.isSpecial -> null
            !issue.chapter.isDefault -> issue.chapter.minNumber
            !issue.volume.isLooseLeaf -> issue.volume.minNumber
            else -> null
        }
    }
    val numbered = numbers.filterNotNull()
    if (numbered.size == numbered.distinct().size) return numbers.map { it?.display() }
    var ordinal = 0
    return issues.map { issue -> if (issue.isSpecial) null else (++ordinal).toString() }
}

private fun Float.display(): String = if (this % 1f == 0f) toInt().toString() else toString()

private fun epochMs(iso: String?): Long? {
    if (iso.isNullOrBlank()) return null
    return runCatching { OffsetDateTime.parse(iso).toInstant().toEpochMilli() }
        .recoverCatching { Instant.parse(iso).toEpochMilli() }
        .recoverCatching { LocalDateTime.parse(iso).toInstant(ZoneOffset.UTC).toEpochMilli() }
        .getOrNull()
        ?.takeIf { it > 0L }
}
