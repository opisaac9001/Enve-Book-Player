package com.enve.app.data.offline

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ComicResumeIntegrityTest {
    @Test
    fun acceptsTheRemainingBytesOfTheValidatedBook() {
        assertEquals(100L, completeBookRangeLength("bytes 60-99/100", 60, 40, "etag-A", "etag-A"))
        assertEquals(100L, completeBookRangeLength("bytes 60-99/100", 60, -1, "etag-A", null))
    }

    @Test
    fun rejectsShiftedTruncatedAndUnknownRanges() {
        for (range in listOf("bytes 55-99/100", "bytes 60-90/100", "bytes 60-99/*", null)) {
            assertThrows(IllegalStateException::class.java) {
                completeBookRangeLength(range, 60, -1, "etag-A", "etag-A")
            }
        }
        assertThrows(IllegalStateException::class.java) {
            completeBookRangeLength("bytes 60-99/100", 60, 10, "etag-A", "etag-A")
        }
    }

    @Test
    fun rejectsAChangedRepresentationOrAnUnvalidatedPartial() {
        for (stored in listOf("etag-B", null)) {
            assertThrows(IllegalStateException::class.java) {
                completeBookRangeLength("bytes 60-99/100", 60, 40, stored, "etag-A")
            }
        }
    }
}
