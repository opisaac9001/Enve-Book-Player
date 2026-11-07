package com.enve.komga

import com.enve.core.data.model.ComicMetadata
import com.enve.core.data.model.ComicSection
import com.enve.komga.dto.KomgaBookDto
import com.enve.komga.dto.KomgaBookMetadataDto
import com.enve.komga.dto.KomgaMediaDto
import com.enve.komga.dto.comicMetadata
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class KomgaComicMetadataTest {
    private fun book(
        media: KomgaMediaDto?,
        seriesId: String = "series-1",
        metadata: KomgaBookMetadataDto? = null,
    ) = KomgaBookDto(
        id = "b", seriesId = seriesId, seriesTitle = "Saga", libraryId = "l", name = "Saga 005", media = media, metadata = metadata,
    )

    @Test
    fun archiveIssuesBecomeFlatIssuesOfTheirServerSeries() {
        val metadata = book(
            KomgaMediaDto(mediaType = "application/zip", mediaProfile = "DIVINA"),
            metadata = KomgaBookMetadataDto(number = "5", numberSort = 5f),
        ).comicMetadata()

        assertEquals(
            ComicMetadata(seriesId = "series-1", section = ComicSection.ISSUES, issueLabel = "Issue 5", issueOrder = 5.0),
            metadata,
        )
    }

    @Test
    fun pdfComicsKeepTheirSeriesIdentity() {
        assertEquals("series-1", book(KomgaMediaDto(mediaType = "application/pdf", mediaProfile = "PDF")).comicMetadata()?.seriesId)
    }

    @Test
    fun proseAndAudioCarryNoComicMetadata() {
        assertNull(book(KomgaMediaDto(mediaType = "application/epub+zip", mediaProfile = "EPUB")).comicMetadata())
        assertNull(book(KomgaMediaDto(mediaType = "audio/mpeg")).comicMetadata())
        assertNull(book(KomgaMediaDto(mediaType = "application/zip"), seriesId = "").comicMetadata())
    }
}
