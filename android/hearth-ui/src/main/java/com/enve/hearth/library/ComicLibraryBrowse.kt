package com.enve.hearth.library

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ComicSection
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

data class ComicVolume(
    val id: String,
    val title: String?,
    val order: Double?,
    val books: List<Book>,
) {
    val displayTitle: String
        get() = title?.takeIf(String::isNotBlank) ?: order?.let { "Volume ${formatComicNumber(it)}" } ?: "Volume"
}

data class ComicSectionGroup(
    val section: ComicSection,
    val looseBooks: List<Book>,
    val volumes: List<ComicVolume>,
) {
    val bookCount: Int get() = looseBooks.size + volumes.sumOf { it.books.size }
    val orderedBooks: List<Book> get() = looseBooks + volumes.flatMap(ComicVolume::books)
    val directVolume: ComicVolume? get() = volumes.singleOrNull()?.takeIf { looseBooks.isEmpty() }
}

data class ComicSeriesGrouping(val sections: List<ComicSectionGroup>) {
    val orderedBooks: List<Book> get() = sections.flatMap(ComicSectionGroup::orderedBooks)
    val bookCount: Int get() = sections.sumOf(ComicSectionGroup::bookCount)

    fun section(section: ComicSection): ComicSectionGroup? = sections.firstOrNull { it.section == section }

    companion object {
        fun of(books: List<Book>): ComicSeriesGrouping {
            class VolumeAccumulator(var title: String?, var order: Double?, val books: MutableList<IndexedValue<Book>>)
            class SectionAccumulator {
                val loose = mutableListOf<IndexedValue<Book>>()
                val volumes = linkedMapOf<String, VolumeAccumulator>()
            }

            val seen = mutableSetOf<String>()
            val sections = sortedMapOf<ComicSection, SectionAccumulator>()
            books.withIndex().filter { seen.add(it.value.uniqueKey) }.forEach { entry ->
                val comic = entry.value.comic
                val section = sections.getOrPut(comic?.section ?: ComicSection.ISSUES, ::SectionAccumulator)
                val volumeId = comic?.volumeId
                if (volumeId == null) {
                    section.loose += entry
                } else {
                    val volume = section.volumes.getOrPut(volumeId) { VolumeAccumulator(null, null, mutableListOf()) }
                    if (volume.title == null) volume.title = comic.volumeTitle
                    if (volume.order == null) volume.order = comic.volumeOrder
                    volume.books += entry
                }
            }
            return ComicSeriesGrouping(
                sections.map { (section, accumulator) ->
                    ComicSectionGroup(
                        section = section,
                        looseBooks = issueOrdered(accumulator.loose),
                        volumes = accumulator.volumes.entries
                            .sortedWith(
                                compareBy<Map.Entry<String, VolumeAccumulator>> { it.value.order == null }
                                    .thenBy { it.value.order ?: 0.0 }
                                    .thenBy { it.value.books.first().index },
                            )
                            .map { (volumeId, volume) ->
                                ComicVolume(comicVolumeKey(section, volumeId), volume.title, volume.order, issueOrdered(volume.books))
                            },
                    )
                },
            )
        }

        private fun issueOrdered(books: List<IndexedValue<Book>>): List<Book> = books
            .sortedWith(
                compareBy<IndexedValue<Book>> { it.value.comic?.issueOrder == null }
                    .thenBy { it.value.comic?.issueOrder ?: 0.0 }
                    .thenBy { it.index },
            )
            .map(IndexedValue<Book>::value)
    }
}

data class ComicSeriesSummary(
    val key: String,
    val name: String,
    val coverUrl: String?,
    val total: Int,
    val unread: Int,
    val run: String?,
    val next: Book?,
)

data class ComicSeriesView(
    val key: String,
    val name: String,
    val isStandalone: Boolean,
    val grouping: ComicSeriesGrouping,
    val selectedSection: ComicSection,
    val expandedVolumeIds: Set<String>,
) {
    val hasNoVisibleIssues: Boolean get() = grouping.sections.isEmpty()
    val current: ComicSectionGroup? get() = grouping.section(selectedSection)
    val total: Int get() = grouping.bookCount
    val unread: Int get() = grouping.orderedBooks.count { !isReadInLibrary(it) }
    val continueBook: Book? get() = nextComicIssue(grouping.orderedBooks)
}

@Serializable
data class ComicBrowseState(
    val facet: LibraryFacet = LibraryFacet.SERIES,
    val columns: Int? = null,
    val seriesKey: String? = null,
    val section: ComicSection? = null,
    val expandedVolumeIds: Set<String> = emptySet(),
)

internal val ComicFacets = listOf(LibraryFacet.SERIES, LibraryFacet.BOOKS)

private val ComicJson = Json { ignoreUnknownKeys = true }

private val ComicMetadataSources = setOf(BookSource.KOMGA, BookSource.KAVITA)

@Serializable
private data class ComicSeriesIdentity(
    val source: BookSource,
    val connectionId: String?,
    val libraryId: String?,
    val seriesId: String? = null,
    val seriesName: String? = null,
    val bookId: String? = null,
)

private fun comicSeriesIdentity(book: Book): ComicSeriesIdentity {
    val seriesId = book.comic?.seriesId
    val seriesName = book.seriesName?.trim()?.takeIf(String::isNotEmpty)
    val scoped = ComicSeriesIdentity(book.source, book.connectionId, book.libraryId)
    return when {
        seriesId != null -> scoped.copy(seriesId = seriesId)
        seriesName != null && book.source !in ComicMetadataSources -> scoped.copy(seriesName = seriesName)
        else -> scoped.copy(bookId = book.id)
    }
}

private fun ComicSeriesIdentity.key(): String = ComicJson.encodeToString(this)

internal fun comicVolumeKey(section: ComicSection, volumeId: String): String = "${section.name}/$volumeId"

internal fun nextComicIssue(ordered: List<Book>): Book? =
    ordered.firstOrNull { !isReadInLibrary(it) && comicProgress(it) > 0.001f }
        ?: ordered.firstOrNull { !isReadInLibrary(it) }
        ?: ordered.firstOrNull()

internal fun comicProgress(book: Book): Float = maxOf(book.readProgress, book.epubProgress ?: 0f)

internal fun comicSeriesSummaries(books: List<Book>): List<ComicSeriesSummary> =
    books.groupBy(::comicSeriesIdentity).map { (identity, members) ->
        val ordered = ComicSeriesGrouping.of(members).orderedBooks
        val years = members.mapNotNull(::publishedYear)
        ComicSeriesSummary(
            key = identity.key(),
            name = comicSeriesName(members),
            coverUrl = ordered.firstNotNullOfOrNull(Book::coverUrl),
            total = members.size,
            unread = members.count { !isReadInLibrary(it) },
            run = years.takeIf { it.isNotEmpty() }?.let { if (it.min() == it.max()) "${it.min()}" else "${it.min()}–${it.max()}" },
            next = nextComicIssue(ordered),
        )
    }.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER, ComicSeriesSummary::name).thenBy { it.key })

internal fun comicSeriesName(members: List<Book>): String =
    members.firstNotNullOfOrNull { it.seriesName?.trim()?.takeIf(String::isNotEmpty) } ?: members.first().title

internal fun comicSeriesView(
    key: String,
    catalog: List<Book>,
    visible: List<Book>,
    state: ComicBrowseState,
): ComicSeriesView? {
    val identity = runCatching { ComicJson.decodeFromString<ComicSeriesIdentity>(key) }.getOrNull() ?: return null
    val members = catalog.filter { comicSeriesIdentity(it) == identity }
    if (members.isEmpty()) return null
    val grouping = ComicSeriesGrouping.of(visible.filter { comicSeriesIdentity(it) == identity })
    val available = grouping.sections.map(ComicSectionGroup::section)
    val resume = nextComicIssue(grouping.orderedBooks)?.comic?.section
    return ComicSeriesView(
        key = key,
        name = comicSeriesName(members),
        isStandalone = identity.bookId != null,
        grouping = grouping,
        selectedSection = state.section?.takeIf { it in available } ?: resume?.takeIf { it in available }
            ?: available.firstOrNull() ?: ComicSection.ISSUES,
        expandedVolumeIds = state.expandedVolumeIds,
    )
}

internal fun openedComicSeriesState(state: ComicBrowseState, series: ComicSeriesSummary): ComicBrowseState {
    val resume = series.next?.comic
    return state.copy(
        seriesKey = series.key,
        section = resume?.section,
        expandedVolumeIds = resume?.volumeId?.let { setOf(comicVolumeKey(resume.section, it)) }.orEmpty(),
    )
}

internal fun formatComicNumber(value: Double): String =
    if (value % 1.0 == 0.0) value.toLong().toString() else value.toString()

internal fun encodeComicBrowseState(state: ComicBrowseState): String = ComicJson.encodeToString(state)

internal fun decodeComicBrowseState(encoded: String): ComicBrowseState {
    val state = runCatching { ComicJson.decodeFromString<ComicBrowseState>(encoded) }.getOrNull() ?: return ComicBrowseState()
    return state.copy(
        facet = state.facet.takeIf { it in ComicFacets } ?: LibraryFacet.SERIES,
        columns = state.columns?.coerceIn(1, 4),
    )
}
