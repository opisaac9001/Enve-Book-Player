package com.enve.audiobookshelf

import com.enve.audiobookshelf.dto.AbsLibraryItemDto
import com.enve.audiobookshelf.dto.AbsMediaDto
import com.enve.core.data.model.AppMediaType
import org.junit.Assert.assertEquals
import org.junit.Test

class AbsMediaTypeResolverTest {

    @Test
    fun classifiesMinifiedEbookFromEbookFormat() {
        val item = AbsLibraryItemDto(
            id = "ebook",
            mediaType = "book",
            media = AbsMediaDto(
                duration = 1_800.0,
                numTracks = 0,
                numAudioFiles = 0,
                ebookFormat = "epub",
            ),
        )

        assertEquals(AppMediaType.EBOOK, resolveAbsMediaType(item))
    }

    @Test
    fun classifiesMinifiedAudiobookFromAudioFileCount() {
        val item = AbsLibraryItemDto(
            id = "audiobook",
            mediaType = "book",
            media = AbsMediaDto(
                numTracks = 0,
                numAudioFiles = 1,
            ),
        )

        assertEquals(AppMediaType.AUDIOBOOK, resolveAbsMediaType(item))
    }

    @Test
    fun preservesPodcastMediaType() {
        val item = AbsLibraryItemDto(
            id = "podcast",
            mediaType = "podcast",
            media = AbsMediaDto(numTracks = 10),
        )

        assertEquals(AppMediaType.PODCAST, resolveAbsMediaType(item))
    }
}
