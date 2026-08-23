package com.enve.local

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.ProviderMetadataUpdate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LocalBookSidecarCodecTest {
    @Test
    fun encodeDecode_preservesEditableMetadata() {
        val encoded = LocalBookSidecarCodec.encode(
            fileName = "Dune.epub",
            metadata = ProviderMetadataUpdate(
                title = "Dune",
                subtitle = "Book One",
                author = "Frank Herbert",
                narrator = "Scott Brick",
                description = "Arrakis and spice.",
                seriesName = "Dune",
                seriesNumber = "1",
                publisher = "Ace",
                publishedDate = "1965",
                isbn13 = "9780441172719",
                language = "en",
                pageCount = 688,
                categories = listOf("Science Fiction", "Classics"),
            ),
            updatedAt = 42L,
        )

        val sidecar = LocalBookSidecarCodec.decode(encoded)

        assertEquals("Dune.epub", sidecar.fileName)
        assertEquals(42L, sidecar.updatedAt)
        assertEquals("Dune", sidecar.metadata.title)
        assertEquals("Book One", sidecar.metadata.subtitle)
        assertEquals("Frank Herbert", sidecar.metadata.author)
        assertEquals("Scott Brick", sidecar.metadata.narrator)
        assertEquals("Arrakis and spice.", sidecar.metadata.description)
        assertEquals("Dune", sidecar.metadata.seriesName)
        assertEquals("1", sidecar.metadata.seriesNumber)
        assertEquals("Ace", sidecar.metadata.publisher)
        assertEquals("1965", sidecar.metadata.publishedDate)
        assertEquals("9780441172719", sidecar.metadata.isbn13)
        assertEquals("en", sidecar.metadata.language)
        assertEquals(688, sidecar.metadata.pageCount)
        assertEquals(listOf("Science Fiction", "Classics"), sidecar.metadata.categories)
    }

    @Test
    fun apply_usesSidecarMetadataAndAllowsClearedOptionalFields() {
        val book = Book(
            id = "content://library/Dune.epub",
            title = "Dune.epub",
            author = "Local",
            source = BookSource.LOCAL,
            mediaType = AppMediaType.EBOOK,
        )
        val sidecar = LocalBookMetadataSidecar(
            fileName = "Dune.epub",
            updatedAt = 42L,
            metadata = LocalBookSidecarMetadata(
                title = "Dune",
                author = null,
                language = "en",
                pageCount = 688,
            ),
        )

        val updated = LocalBookSidecarCodec.apply(book, sidecar)

        assertEquals("Dune", updated.title)
        assertNull(updated.author)
        assertEquals("en", updated.language)
        assertEquals(688, updated.pageCount)
        assertEquals(BookSource.LOCAL, updated.source)
        assertEquals(AppMediaType.EBOOK, updated.mediaType)
    }

    @Test
    fun sidecarName_keepsOriginalExtensionToAvoidCollisions() {
        assertEquals("Dune.epub.enve.json", LocalBookSidecarCodec.sidecarName("Dune.epub"))
    }
}
