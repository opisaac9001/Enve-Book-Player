package com.enve.app.data.repository.grimmory

import org.junit.Assert.assertEquals
import org.junit.Test

class GrimmoryContentUrlTest {
    @Test
    fun `download URL lets Grimmory select the primary file type`() {
        assertEquals(
            "http://grimmory.test/api/v1/books/42/content",
            grimmoryBookContentUrl("http://grimmory.test/", "42"),
        )
    }

    @Test
    fun `EPUB resource URL keeps its explicit file type`() {
        assertEquals(
            "http://grimmory.test/api/v1/books/42/content?bookType=EPUB",
            grimmoryBookContentUrl("http://grimmory.test", "42", bookType = "EPUB"),
        )
    }
}
