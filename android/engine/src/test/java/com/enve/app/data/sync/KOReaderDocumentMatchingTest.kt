package com.enve.app.data.sync

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.sync.KOReaderProgress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.security.MessageDigest

class KOReaderDocumentMatchingTest {

    private fun referenceMd5(value: String): String =
        MessageDigest.getInstance("MD5").digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    private fun book(id: String) = Book(
        id = id,
        title = "Dune",
        source = BookSource.LOCAL,
        mediaType = AppMediaType.EBOOK,
    )

    @Test
    fun filename_hash_matches_crosspoint_md5_of_the_bare_name() {
        assertEquals(referenceMd5("Dune.epub"), KOReaderDocumentId.fromFilename("Dune.epub"))
        assertEquals(referenceMd5("Dune.epub"), KOReaderDocumentId.fromFilename("/sdcard/books/Dune.epub"))
        assertEquals(referenceMd5("Dune.epub"), KOReaderDocumentId.fromFilename("D:\\books\\Dune.epub"))
    }

    @Test
    fun filename_hash_handles_unicode_and_percent_encoded_paths() {
        assertEquals(
            referenceMd5("Café 中文.epub"),
            KOReaderDocumentId.fromFilename("content://tree/primary%3ABooks%2FCaf%C3%A9%20%E4%B8%AD%E6%96%87.epub"),
        )
        assertEquals(referenceMd5("a+b.epub"), KOReaderDocumentId.fromFilename("/books/a+b.epub"))
        assertNull(KOReaderDocumentId.fromFilename("   "))
    }

    @Test
    fun filename_is_only_suggested_for_ids_that_name_an_ebook_file() {
        assertEquals(
            "Dune.epub",
            KOReaderDocumentId.filenameSuggestion(
                book("content://com.android.externalstorage.documents/document/primary%3ABooks%2FDune.epub"),
            ),
        )
        assertEquals("Dune.epub", KOReaderDocumentId.filenameSuggestion(book("/storage/emulated/0/Books/Dune.epub")))
        assertNull(KOReaderDocumentId.filenameSuggestion(book("li_9f3ac21b")))
        assertNull(KOReaderDocumentId.filenameSuggestion(book("https://server/api/items/42")))
    }

    @Test
    fun remote_record_selection_prefers_the_newest_usable_timestamp() {
        val primary = KOReaderProgress(document = "a".repeat(32), percentage = 0.40, timestamp = 1_000L)
        val newer = KOReaderProgress(document = "b".repeat(32), percentage = 0.10, timestamp = 2_000L)

        assertEquals(newer, KOReaderHubService.selectRemoteRecord(listOf(primary, newer)))
        assertEquals(newer, KOReaderHubService.selectRemoteRecord(listOf(newer, primary)))
    }

    @Test
    fun remote_record_selection_falls_back_to_the_first_candidate() {
        val primary = KOReaderProgress(document = "a".repeat(32), percentage = 0.40)
        val alternate = KOReaderProgress(document = "b".repeat(32), percentage = 0.90)

        assertNull(KOReaderHubService.selectRemoteRecord(emptyList()))
        assertEquals(primary, KOReaderHubService.selectRemoteRecord(listOf(primary, alternate)))
        assertEquals(primary, KOReaderHubService.selectRemoteRecord(listOf(primary)))
    }

    @Test
    fun remote_record_selection_keeps_the_first_candidate_on_a_timestamp_tie() {
        val primary = KOReaderProgress(document = "a".repeat(32), percentage = 0.40, timestamp = 5_000L)
        val alternate = KOReaderProgress(document = "b".repeat(32), percentage = 0.90, timestamp = 5_000L)

        assertEquals(primary, KOReaderHubService.selectRemoteRecord(listOf(primary, alternate)))
        assertEquals(alternate, KOReaderHubService.selectRemoteRecord(listOf(alternate, primary)))
    }

    @Test
    fun remote_record_selection_ignores_an_unset_timestamp() {
        val stale = KOReaderProgress(document = "a".repeat(32), percentage = 0.90, timestamp = 0L)
        val dated = KOReaderProgress(document = "b".repeat(32), percentage = 0.10, timestamp = 9L)

        assertEquals(dated, KOReaderHubService.selectRemoteRecord(listOf(stale, dated)))
    }
}
