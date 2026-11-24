package com.enve.app.data.offline

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OfflineDownloadKeyTest {
    private val book = Book(id = "42", title = "Book", mediaType = AppMediaType.AUDIOBOOK, source = BookSource.AUDIOBOOKSHELF)

    @Test
    fun sameBookIdOnTwoConnectionsGetsDistinctKeys() {
        val first = book.copy(connectionId = "abs-a").offlineDownloadKey
        val second = book.copy(connectionId = "abs-b").offlineDownloadKey

        assertNotEquals(first, second)
        assertEquals(first, book.copy(connectionId = "abs-a", title = "Renamed").offlineDownloadKey)
    }

    @Test
    fun sourceAndMissingConnectionArePartOfTheIdentity() {
        val keys = setOf(
            offlineDownloadKey(BookSource.AUDIOBOOKSHELF, null, "42"),
            offlineDownloadKey(BookSource.AUDIOBOOKSHELF, "", "42"),
            offlineDownloadKey(BookSource.KOMGA, null, "42"),
            offlineDownloadKey(BookSource.AUDIOBOOKSHELF, "null", "42"),
        )

        assertEquals(4, keys.size)
    }

    @Test
    fun punctuationThatLegacySanitizingMergedStaysDistinct() {
        val slash = offlineDownloadKey(BookSource.OPDS, "opds", "urn:a/b")
        val colon = offlineDownloadKey(BookSource.OPDS, "opds", "urn:a:b")
        val underscore = offlineDownloadKey(BookSource.OPDS, "opds", "urn_a_b")

        assertEquals(legacyOfflineDirectoryName("urn:a/b"), legacyOfflineDirectoryName("urn:a:b"))
        assertEquals(3, setOf(slash, colon, underscore).size)
    }

    @Test
    fun separatorsInsideComponentsCannotForgeAnotherIdentity() {
        assertNotEquals(
            offlineDownloadKey(BookSource.KOMGA, "a\",\"b", "c"),
            offlineDownloadKey(BookSource.KOMGA, "a", "b\",\"c"),
        )
    }

    @Test
    fun keysAreSingleFilesystemSafeSegments() {
        val key = offlineDownloadKey(BookSource.OPDS, "conn/../x", "https://example.com/" + "a".repeat(2_000))

        assertTrue(key.matches(Regex("dl-[0-9a-f]{64}")))
    }

    @Test
    fun importedLocalFilesKeepTheirExistingDirectoryName() {
        assertEquals("local-file-abc123", offlineDownloadKey(BookSource.LOCAL, null, "local-file-abc123"))
        assertNotEquals("local-file-abc123", offlineDownloadKey(BookSource.LOCAL, "local-conn", "local-file-abc123"))
        assertTrue(offlineDownloadKey(BookSource.LOCAL, null, "../escape").startsWith("dl-"))
    }

    @Test
    fun managedLocalDownloadsExcludeFolderDocumentsAndProviderIds() {
        for (id in listOf("local-file-abc123", "local-import-123", recoveredLocalBookId("ebook", "42"))) {
            assertTrue(isManagedLocalDownload(BookSource.LOCAL, null, id))
            assertFalse(isManagedLocalDownload(BookSource.LOCAL, "folder", id))
            assertFalse(isManagedLocalDownload(BookSource.OPDS, null, id))
        }
        assertFalse(isManagedLocalDownload(BookSource.LOCAL, null, "content://documents/local-file-abc123"))
        assertFalse(isManagedLocalDownload(BookSource.LOCAL, null, "file:///books/book.epub"))
        assertFalse(isManagedLocalDownload(BookSource.LOCAL, null, "../local-file-abc123"))
    }

    @Test
    fun recoveredLocalCopiesAreDeterministicPerStorageIdentityAndUseFullKeys() {
        val audio = recoveredLocalBookId("audio", "42")

        assertEquals(audio, recoveredLocalBookId("audio", "42"))
        assertNotEquals(audio, recoveredLocalBookId("ebook", "42"))
        assertNotEquals(audio, recoveredLocalBookId("audio", "43"))
        assertTrue(isRecoveredLocalBookId(audio))
        assertTrue(offlineDownloadKey(BookSource.LOCAL, null, audio).matches(Regex("dl-[0-9a-f]{64}")))
        assertNotEquals(offlineDownloadKey(BookSource.LOCAL, null, audio), offlineDownloadKey(BookSource.AUDIOBOOKSHELF, null, "42"))
    }
}
