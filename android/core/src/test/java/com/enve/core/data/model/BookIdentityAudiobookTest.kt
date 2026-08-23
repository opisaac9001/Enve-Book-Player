package com.enve.core.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class BookIdentityAudiobookTest {
    @Test
    fun audiobookWithoutDurationDoesNotFormWorkIdentity() {
        val book = Book(
            id = "75",
            title = "Spellmonger",
            author = "Terry Mancour",
            mediaType = AppMediaType.AUDIOBOOK,
        )

        assertEquals("", BookIdentity.workKey(book))
    }

    @Test
    fun audiobookRuntimeSeparatesOtherwiseIdenticalMetadata() {
        val first = Book(
            id = "75",
            title = "Spellmonger",
            author = "Terry Mancour",
            mediaType = AppMediaType.AUDIOBOOK,
            duration = 78_345,
        )
        val second = first.copy(id = "89", duration = 64_210)

        assertNotEquals(BookIdentity.workKey(first), BookIdentity.workKey(second))
    }
}
