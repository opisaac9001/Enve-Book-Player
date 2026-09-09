package com.enve.hearth.design

import com.enve.core.data.model.AppMediaType
import org.junit.Assert.assertEquals
import org.junit.Test

class CoverTileTest {

    @Test
    fun usesPortraitFramesForEbooksAndFallbackArtwork() {
        assertEquals(2f / 3f, coverAspectRatio(AppMediaType.EBOOK), 0f)
        assertEquals(2f / 3f, coverAspectRatio(null), 0f)
    }

    @Test
    fun usesSquareFramesForAudioArtwork() {
        assertEquals(1f, coverAspectRatio(AppMediaType.AUDIOBOOK), 0f)
        assertEquals(1f, coverAspectRatio(AppMediaType.PODCAST), 0f)
    }
}
