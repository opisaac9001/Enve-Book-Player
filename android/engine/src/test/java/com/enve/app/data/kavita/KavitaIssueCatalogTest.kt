package com.enve.app.data.kavita

import com.enve.app.data.remote.dto.KavitaChapterDto
import com.enve.app.data.remote.dto.KavitaMangaFileDto
import com.enve.app.data.remote.dto.KavitaMangaFormat
import com.enve.app.data.remote.dto.KavitaSeriesDto
import com.enve.app.data.remote.dto.KavitaVolumeDto
import com.enve.app.data.repository.kavitaPageNum
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class KavitaIssueCatalogTest {
    private val server = "https://kavita.test/"
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        encodeDefaults = true
    }

    private val syntheticSeries = KavitaSeriesDto(id = 28, name = "Synthetic", libraryId = 2, format = KavitaMangaFormat.ARCHIVE)

    private val syntheticVolumes = json.decodeFromString<List<KavitaVolumeDto>>(
        """
        [{"id":34,"minNumber":-100000,"name":"-100000","seriesId":28,"chapters":[
          {"id":54,"range":"3","minNumber":3,"sortOrder":3,"isSpecial":false,"title":"3","titleName":"",
           "pages":3,"pagesRead":2,"lastReadingProgressUtc":"2026-10-01T12:00:00Z","createdUtc":"2026-09-01T00:00:00",
           "files":[{"id":1,"format":1,"pages":3}]},
          {"id":55,"range":"4","minNumber":4,"sortOrder":4,"isSpecial":false,"title":"4","titleName":"",
           "pages":4,"pagesRead":0,"lastReadingProgressUtc":"0001-01-01T00:00:00","createdUtc":"2026-09-02T00:00:00",
           "files":[{"id":2,"format":1,"pages":4}]}]}]
        """,
    )

    @Test
    fun liveSyntheticIssuesAreIndependentlyIdentified() {
        val books = expandKavitaSeries(syntheticSeries, syntheticVolumes, legacyChapterId = 54, serverUrl = server, fallbackLibraryId = null)

        assertEquals(listOf("28", "28:34:55"), books.map { it.id })
        assertEquals(listOf("Synthetic #3", "Synthetic #4"), books.map { it.title })
        assertEquals(listOf(3, 4), books.map { it.pageCount })
        assertTrue(books.none { it.isFinished })
        assertEquals(listOf("3", "4"), books.map { it.seriesNumber })
        assertEquals(listOf("Synthetic", "Synthetic"), books.map { it.seriesName })
        assertEquals(2f / 3f, books[0].readProgress, 0.0001f)
        assertEquals(0f, books[1].readProgress)
        assertTrue(books[0].lastReadTime > 0L)
        assertEquals(0L, books[1].lastReadTime)
        assertEquals(
            listOf(
                "https://kavita.test/api/Image/chapter-cover?chapterId=54",
                "https://kavita.test/api/Image/chapter-cover?chapterId=55",
            ),
            books.map { it.coverUrl },
        )
        assertEquals(listOf("CBX", "CBX"), books.map { it.primaryFileType })
        assertEquals(listOf("2", "2"), books.map { it.libraryId })
    }

    @Test
    fun multiVolumeSeriesExpandsEveryReadableIssueInReadingOrder() {
        val volumes = listOf(
            KavitaVolumeDto(id = 12, minNumber = 100_000f, name = "100000", chapters = listOf(
                chapter(id = 120, range = "Annual", minNumber = -100_000f, isSpecial = true, title = "Annual"),
            )),
            KavitaVolumeDto(id = 11, minNumber = 2f, name = "2", chapters = listOf(
                chapter(id = 111, range = "2", minNumber = 2f),
                chapter(id = 110, range = "1", minNumber = 1f),
            )),
            KavitaVolumeDto(id = 13, minNumber = 3f, name = "3"),
            KavitaVolumeDto(id = 10, minNumber = 1f, name = "1", chapters = listOf(
                chapter(id = 100, range = "1", minNumber = 1f),
                chapter(id = 101, range = "2", minNumber = 2f),
                chapter(id = 102, range = "3", minNumber = 3f, pages = 0),
            )),
            KavitaVolumeDto(id = 14, minNumber = -100_000f, name = "-100000", chapters = listOf(
                chapter(id = 140, range = "5", minNumber = 5f),
            )),
        )

        val books = expandKavitaSeries(
            KavitaSeriesDto(id = 7, name = "Saga", format = KavitaMangaFormat.ARCHIVE),
            volumes,
            legacyChapterId = 120,
            serverUrl = server,
            fallbackLibraryId = "lib",
        )

        assertEquals(listOf("7:10:100", "7:10:101", "7:11:110", "7:11:111", "7:14:140", "7"), books.map { it.id })
        assertEquals(
            listOf("Saga Vol. 1 #1", "Saga Vol. 1 #2", "Saga Vol. 2 #1", "Saga Vol. 2 #2", "Saga #5", "Saga: Annual"),
            books.map { it.title },
        )
        assertEquals(listOf("1", "2", "3", "4", "5", null), books.map { it.seriesNumber })
        assertEquals(books.size, books.map { it.id }.toSet().size)
        assertEquals(setOf("lib"), books.map { it.libraryId }.toSet())
    }

    @Test
    fun volumeOnlyChaptersUseVolumeLabelAndNumber() {
        val volumes = listOf(
            KavitaVolumeDto(id = 1, minNumber = 1f, name = "1", chapters = listOf(chapter(id = 11, range = "-100000", minNumber = -100_000f))),
            KavitaVolumeDto(id = 2, minNumber = 2f, name = "2", chapters = listOf(chapter(id = 21, range = "-100000", minNumber = -100_000f))),
        )

        val books = expandKavitaSeries(KavitaSeriesDto(id = 3, name = "Novel"), volumes, legacyChapterId = 11, serverUrl = server, fallbackLibraryId = null)

        assertEquals(listOf("3", "3:2:21"), books.map { it.id })
        assertEquals(listOf("Novel Vol. 1", "Novel Vol. 2"), books.map { it.title })
        assertEquals(listOf("1", "2"), books.map { it.seriesNumber })
    }

    @Test
    fun formatAndTitleComeFromEachChapter() {
        val volumes = listOf(
            KavitaVolumeDto(id = 5, minNumber = -100_000f, chapters = listOf(
                chapter(id = 50, range = "1", minNumber = 1f, titleName = "Arrival", files = listOf(KavitaMangaFileDto(KavitaMangaFormat.EPUB))),
                chapter(id = 51, range = "2", minNumber = 2f, format = KavitaMangaFormat.PDF),
                chapter(id = 52, range = "3", minNumber = 3f),
            )),
        )

        val books = expandKavitaSeries(
            KavitaSeriesDto(id = 9, name = "Mixed", format = KavitaMangaFormat.ARCHIVE),
            volumes,
            legacyChapterId = 50,
            serverUrl = server,
            fallbackLibraryId = null,
        )

        assertEquals(listOf("EPUB", "PDF", "CBX"), books.map { it.primaryFileType })
        assertEquals(listOf("Mixed #1: Arrival", "Mixed #2", "Mixed #3"), books.map { it.title })
    }

    @Test
    fun singleChapterBookKeepsLegacyIdentityAndPresentation() {
        val series = KavitaSeriesDto(id = 20, name = "Two Centuries of Costume", libraryId = 1, format = KavitaMangaFormat.EPUB, pages = 20, pagesRead = 8)
        val volumes = listOf(
            KavitaVolumeDto(id = 23, minNumber = -100_000f, chapters = listOf(
                chapter(id = 25, range = "-100000", minNumber = -100_000f, pages = 20, pagesRead = 8),
            )),
        )

        val book = expandKavitaSeries(series, volumes, legacyChapterId = 25, serverUrl = server, fallbackLibraryId = null).single()

        assertEquals("20", book.id)
        assertEquals("Two Centuries of Costume", book.title)
        assertNull(book.seriesName)
        assertNull(book.seriesNumber)
        assertEquals("EPUB", book.primaryFileType)
        assertEquals(0.4f, book.readProgress, 0.0001f)
    }

    @Test
    fun removedLegacyChapterLeavesNoBookOnTheNumericAlias() {
        val books = expandKavitaSeries(syntheticSeries, syntheticVolumes, legacyChapterId = 53, serverUrl = server, fallbackLibraryId = null)

        assertEquals(listOf("28:34:54", "28:34:55"), books.map { it.id })
    }

    @Test
    fun seriesWithoutReadableChaptersExpandsToNothing() {
        val volumes = listOf(KavitaVolumeDto(id = 1), KavitaVolumeDto(id = 2, chapters = listOf(chapter(id = 3, range = "1", minNumber = 1f, pages = 0))))

        assertTrue(expandKavitaSeries(syntheticSeries, volumes, legacyChapterId = 3, serverUrl = server, fallbackLibraryId = null).isEmpty())
    }

    @Test
    fun parsesLegacyAndCompositeIds() {
        assertEquals(KavitaBookRef.Legacy(28), kavitaBookRef("28"))
        assertEquals(KavitaBookRef.Issue(28, 34, 55), kavitaBookRef("28:34:55"))
        assertEquals("28:34:55", kavitaIssueBookId(28, 34, 55))
        assertNull(kavitaBookRef("28:34"))
        assertNull(kavitaBookRef("28:34:55:1"))
        assertNull(kavitaBookRef("series"))
        assertNull(kavitaBookRef(""))
    }

    @Test
    fun legacyCandidateFollowsOriginalApiOrder() {
        val volumes = listOf(
            KavitaVolumeDto(id = 1),
            KavitaVolumeDto(id = 2, chapters = listOf(chapter(id = 9, range = "9", minNumber = 9f), chapter(id = 4, range = "4", minNumber = 4f))),
        )

        assertEquals(9, kavitaLegacyChapterCandidate(volumes))
        assertNull(kavitaLegacyChapterCandidate(listOf(KavitaVolumeDto(id = 1))))
    }

    @Test
    fun progressRoutesToTheRequestedChapter() {
        val issue = resolveKavitaIssue(KavitaBookRef.Issue(28, 34, 55), syntheticVolumes, legacyChapterId = null)

        assertEquals(28, issue.seriesId)
        assertEquals(34, issue.volume.id)
        assertEquals(55, issue.chapter.id)
        assertEquals(2, kavitaPageNum(0.5f, issue.chapter.pages))
        assertEquals(4, kavitaPageNum(1f, issue.chapter.pages))
    }

    @Test
    fun legacyIdResolvesThePinnedChapterNotTheCurrentFirst() {
        val reordered = listOf(syntheticVolumes.single().copy(chapters = syntheticVolumes.single().chapters.reversed()))

        val issue = resolveKavitaIssue(KavitaBookRef.Legacy(28), reordered, legacyChapterId = 54)

        assertEquals(55, kavitaLegacyChapterCandidate(reordered))
        assertEquals(54, issue.chapter.id)
        assertEquals(3, issue.chapter.pages)
    }

    @Test
    fun removedPinnedChapterFailsInsteadOfFallingBack() {
        assertThrows(IllegalStateException::class.java) {
            resolveKavitaIssue(KavitaBookRef.Legacy(28), syntheticVolumes, legacyChapterId = 53)
        }
        assertThrows(IllegalStateException::class.java) {
            resolveKavitaIssue(KavitaBookRef.Legacy(28), emptyList(), legacyChapterId = null)
        }
    }

    @Test
    fun staleCompositeIdFailsWhenChapterLeavesItsVolume() {
        val moved = listOf(
            KavitaVolumeDto(id = 34, minNumber = -100_000f, chapters = syntheticVolumes.single().chapters.take(1)),
            KavitaVolumeDto(id = 35, minNumber = 1f, chapters = syntheticVolumes.single().chapters.drop(1)),
        )

        assertThrows(IllegalStateException::class.java) {
            resolveKavitaIssue(KavitaBookRef.Issue(28, 34, 55), moved, legacyChapterId = null)
        }
        assertThrows(IllegalStateException::class.java) {
            resolveKavitaIssue(KavitaBookRef.Issue(28, 34, 99), syntheticVolumes, legacyChapterId = null)
        }
        assertEquals(55, resolveKavitaIssue(KavitaBookRef.Issue(28, 35, 55), moved, legacyChapterId = null).chapter.id)
    }

    private fun chapter(
        id: Int,
        range: String,
        minNumber: Float,
        pages: Int = 10,
        pagesRead: Int = 0,
        isSpecial: Boolean = false,
        title: String? = range,
        titleName: String? = null,
        format: Int? = null,
        files: List<KavitaMangaFileDto> = emptyList(),
    ) = KavitaChapterDto(
        id = id,
        range = range,
        minNumber = minNumber,
        sortOrder = minNumber,
        isSpecial = isSpecial,
        title = title,
        titleName = titleName,
        pages = pages,
        pagesRead = pagesRead,
        format = format,
        files = files,
    )
}
