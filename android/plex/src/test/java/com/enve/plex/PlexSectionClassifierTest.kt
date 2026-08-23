package com.enve.plex

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlexSectionClassifierTest {

    @Test
    fun normalMusicSection_isNotAudiobookSection() {
        assertFalse(
            isLikelyPlexAudiobookSection(
                type = "artist",
                title = "Music",
                agent = "tv.plex.agents.music",
                scanner = "Plex Music Scanner",
            ),
        )
    }

    @Test
    fun audiobookTitle_isAudiobookSection() {
        assertTrue(
            isLikelyPlexAudiobookSection(
                type = "artist",
                title = "Audiobooks",
                agent = "tv.plex.agents.music",
                scanner = "Plex Music Scanner",
            ),
        )
    }

    @Test
    fun audnexusAgent_isAudiobookSection() {
        assertTrue(
            isLikelyPlexAudiobookSection(
                type = "artist",
                title = "Library",
                agent = "com.plexapp.agents.audnexus",
                scanner = "Plex Music Scanner",
            ),
        )
    }

    @Test
    fun nonAudioSection_isNotAudiobookSection() {
        assertFalse(
            isLikelyPlexAudiobookSection(
                type = "movie",
                title = "Books",
                agent = "com.plexapp.agents.audnexus",
                scanner = "Plex Movie Scanner",
            ),
        )
    }
}
