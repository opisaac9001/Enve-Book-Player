package com.enve.app.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceAudiobookSearchTest {
    @Test
    fun `blank request represents playback resumption`() {
        assertTrue(VoiceAudiobookSearch.create("  ", null, null).isEmpty)
    }

    @Test
    fun `title request matches case insensitively`() {
        val search = VoiceAudiobookSearch.create(null, "atomic habits", null)

        assertTrue(search.matches("Atomic Habits", "James Clear", null))
        assertFalse(search.matches("The Hobbit", "J.R.R. Tolkien", null))
    }

    @Test
    fun `generic query searches authors and narrators`() {
        val authorSearch = VoiceAudiobookSearch.create("le guin", null, null)
        val narratorSearch = VoiceAudiobookSearch.create("guidall", null, null)

        assertTrue(authorSearch.matches("The Dispossessed", "Ursula K. Le Guin", null))
        assertTrue(narratorSearch.matches("American Gods", "Neil Gaiman", "George Guidall"))
    }

    @Test
    fun `exact title ranks ahead of a partial title`() {
        val search = VoiceAudiobookSearch.create("dune", null, null)

        assertEquals(0, search.rank("Dune", "Frank Herbert", null))
        assertTrue(
            search.rank("Dune Messiah", "Frank Herbert", null) >
                search.rank("Dune", "Frank Herbert", null)
        )
    }

    @Test
    fun `creator disambiguates equal titles`() {
        val search = VoiceAudiobookSearch.create(null, "The Odyssey", "Emily Wilson")

        assertTrue(
            search.rank("The Odyssey", "Emily Wilson", null) <
                search.rank("The Odyssey", "Robert Fagles", null)
        )
    }
}
