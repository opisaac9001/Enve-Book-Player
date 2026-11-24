package com.enve.app.ui.screens

import com.enve.app.document.EbookSourceFormat
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ReaderPublicationFileTest {
    @get:Rule val folder = TemporaryFolder()

    @Test fun interruptedDownloadPreservesCachedEdition() {
        val book = folder.newFile("book.azw3").apply { writeText("previous edition") }

        assertThrows(IOException::class.java) {
            book.writePublication(EbookSourceFormat.AZW3) {
                it.write(1)
                throw IOException("Connection closed")
            }
        }

        assertEquals("previous edition", book.readText())
        assertEquals(listOf(book), folder.root.listFiles()!!.toList())
    }
}
