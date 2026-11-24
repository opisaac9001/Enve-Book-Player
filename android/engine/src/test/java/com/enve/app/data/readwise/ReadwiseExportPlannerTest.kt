package com.enve.app.data.readwise

import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.ReaderAnnotation
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class ReadwiseExportPlannerTest {
    @get:Rule val folder = TemporaryFolder()

    private val dune = ReadwiseBookInfo("Dune", "Frank Herbert")
    private val books: (ReaderAnnotation) -> ReadwiseBookInfo? = { dune }

    @Test fun excludesDeletedBookmarksAndEmptySelections() {
        val plan = ReadwiseExportPlanner.plan(
            listOf(
                annotation("keep", selectedText = "Fear is the mind-killer."),
                annotation("deleted", selectedText = "Gone", deletedAt = 5L),
                annotation("bookmark", selectedText = "Marked", kind = AnnotationKind.BOOKMARK),
                annotation("blank", selectedText = "   ", note = "Note only", kind = AnnotationKind.NOTE),
                annotation("note", selectedText = "Attached", note = "Thought", kind = AnnotationKind.NOTE),
            ),
            books,
            emptyMap(),
        )

        assertEquals(listOf("keep", "note"), plan.pending.map { it.annotationId }.sorted())
        assertEquals(3, plan.excludedCount)
        assertEquals(0, plan.alreadySentCount)
        assertEquals(0, plan.oversizedCount)
    }

    @Test fun receiptsSkipUnchangedAndCarryRemoteIdForEditedHighlights() {
        val original = annotation("a", selectedText = "Text", note = "First")
        val untouched = annotation("b", selectedText = "Other")
        val first = ReadwiseExportPlanner.plan(listOf(original, untouched), books, emptyMap())
        assertTrue(first.pending.none { it.changed })
        val receipts = first.pending.withIndex().associate { (index, item) -> item.annotationId to ReadwiseReceipt(100L + index, item.fingerprint) }

        val second = ReadwiseExportPlanner.plan(listOf(original.copy(note = "Edited"), untouched), books, receipts)

        assertEquals(1, second.alreadySentCount)
        val edited = second.pending.single()
        assertEquals("a", edited.annotationId)
        assertEquals(receipts.getValue("a").remoteId, edited.remoteId)
        assertTrue(edited.changed)
    }

    @Test fun changedTextIsPendingAgainUnderTheSameRemoteHighlight() {
        val original = annotation("a", selectedText = "Text")
        val receipt = ReadwiseExportPlanner.plan(listOf(original), books, emptyMap()).pending.single()
            .let { ReadwiseReceipt(7, it.fingerprint) }

        val plan = ReadwiseExportPlanner.plan(listOf(original.copy(selectedText = "Text, corrected")), books, mapOf("a" to receipt))

        assertEquals(7L, plan.pending.single().remoteId)
        assertEquals("Text, corrected", plan.pending.single().payload.text)
    }

    @Test fun bookMetadataChangesDoNotResendAConfirmedHighlight() {
        val a = annotation("a", selectedText = "Text")
        val receipts = ReadwiseExportPlanner.plan(listOf(a), books, emptyMap()).pending
            .associate { it.annotationId to ReadwiseReceipt(1, it.fingerprint) }

        val renamed = ReadwiseExportPlanner.plan(listOf(a), { ReadwiseBookInfo("Dune (Deluxe)", "Frank Herbert") }, receipts)

        assertTrue(renamed.pending.isEmpty())
        assertEquals(1, renamed.alreadySentCount)
    }

    @Test fun oversizedTextOrNotesAreCountedAndNeverSentOrTruncated() {
        val plan = ReadwiseExportPlanner.plan(
            listOf(
                annotation("long-text", selectedText = "x".repeat(8192)),
                annotation("long-note", selectedText = "ok", note = "n".repeat(8192)),
                annotation("at-limit", selectedText = "y".repeat(8191), note = "z".repeat(8191)),
            ),
            books,
            emptyMap(),
        )

        assertEquals(2, plan.oversizedCount)
        assertEquals(listOf("at-limit"), plan.pending.map { it.annotationId })
        assertEquals(8191, plan.pending.single().payload.text.length)
    }

    @Test fun limitsCountCodePointsNotUtf16Units() {
        val emoji = "\uD83D\uDCD6"
        val plan = ReadwiseExportPlanner.plan(listOf(annotation("e", selectedText = emoji.repeat(8191))), books, emptyMap())

        assertEquals(0, plan.oversizedCount)
        assertEquals(1, plan.pending.size)
    }

    @Test fun payloadUsesOnlyRealNonNegativeLocations() {
        val epub = ReadwiseHighlightMapper.payload(annotation("e", selectedText = "x", progression = 0.4, totalProgression = 0.4), null)
        val pdf = ReadwiseHighlightMapper.payload(annotation("p", selectedText = "x", media = AnnotationMedia.PDF, pdfPage = 9), null)
        val comic = ReadwiseHighlightMapper.payload(annotation("c", selectedText = "x", media = AnnotationMedia.CBZ, cbzPage = 0), null)
        val audio = ReadwiseHighlightMapper.payload(annotation("a", selectedText = "x", media = AnnotationMedia.AUDIOBOOK, audioPositionMs = 61_999), null)
        val pdfWithoutPage = ReadwiseHighlightMapper.payload(annotation("q", selectedText = "x", media = AnnotationMedia.PDF), null)
        val negativePage = ReadwiseHighlightMapper.payload(annotation("n", selectedText = "x", media = AnnotationMedia.PDF, pdfPage = -1), null)
        val negativeComic = ReadwiseHighlightMapper.payload(annotation("m", selectedText = "x", media = AnnotationMedia.CBZ, cbzPage = -3), null)
        val negativeAudio = ReadwiseHighlightMapper.payload(annotation("o", selectedText = "x", media = AnnotationMedia.AUDIOBOOK, audioPositionMs = -500), null)

        assertNull(epub.location)
        assertNull(epub.locationType)
        assertEquals(10L, pdf.location)
        assertEquals("page", pdf.locationType)
        assertEquals(1L, comic.location)
        assertEquals(61L, audio.location)
        assertEquals("time_offset", audio.locationType)
        listOf(pdfWithoutPage, negativePage, negativeComic, negativeAudio).forEach {
            assertNull(it.location)
            assertNull(it.locationType)
        }
    }

    @Test fun payloadTrimsTextAndUsesTheEnveSourceType() {
        val payload = ReadwiseHighlightMapper.payload(
            annotation("a", selectedText = "  quoted  ", note = "   ", createdAt = 0L),
            null,
        )

        assertEquals("quoted", payload.text)
        assertNull(payload.note)
        assertNull(payload.title)
        assertEquals("enve_book_player", payload.sourceType)
        assertEquals("1970-01-01T00:00:00Z", payload.highlightedAt)
    }

    @Test fun bookInfoMatchesProviderAndBoundsMetadata() {
        val info = ReadwiseHighlightMapper.bookInfo(
            listOf(ReadwiseCatalogBook("GRIMMORY", "  ", "A".repeat(2000)), ReadwiseCatalogBook("KOMGA", "Other", "Someone")),
            "grimmory",
        )

        assertNull(info!!.title)
        assertEquals(1024, info.author!!.length)
    }

    @Test fun bookInfoOmitsMetadataWhenIdsCollideAmbiguously() {
        val sameIdAcrossProviders = listOf(ReadwiseCatalogBook("GRIMMORY", "Dune", "Herbert"), ReadwiseCatalogBook("KOMGA", "Saga", "Vaughan"))
        val sameIdAcrossConnections = listOf(ReadwiseCatalogBook("GRIMMORY", "Dune", "Herbert"), ReadwiseCatalogBook("GRIMMORY", "Emma", "Austen"))
        val duplicatedRows = listOf(ReadwiseCatalogBook("GRIMMORY", "Dune ", "Herbert"), ReadwiseCatalogBook("GRIMMORY", "Dune", " Herbert"))

        assertEquals(ReadwiseBookInfo("Saga", "Vaughan"), ReadwiseHighlightMapper.bookInfo(sameIdAcrossProviders, "komga"))
        assertNull(ReadwiseHighlightMapper.bookInfo(sameIdAcrossProviders, "local"))
        assertNull(ReadwiseHighlightMapper.bookInfo(sameIdAcrossConnections, "grimmory"))
        assertEquals(ReadwiseBookInfo("Dune", "Herbert"), ReadwiseHighlightMapper.bookInfo(duplicatedRows, "grimmory"))
    }

    @Test fun accountFingerprintsSeparateAccountsWithoutStoringTokens() {
        val one = ReadwiseHighlightMapper.accountFingerprint("token-one")
        val two = ReadwiseHighlightMapper.accountFingerprint("token-two")

        assertNotEquals(one, two)
        assertEquals(one, ReadwiseHighlightMapper.accountFingerprint("token-one"))
        assertFalse(one.contains("token-one"))
    }

    @Test fun receiptsAreIsolatedPerAccountAndPerProfile() = runBlocking {
        val root = folder.newFolder()
        val owner = ReadwiseReceiptStore(locations(root))
        val child = ReadwiseReceiptStore(locations(root, "kid_1"))

        owner.record("account-a", mapOf("x" to ReadwiseReceipt(1, "f1")))
        owner.record("account-b", mapOf("x" to ReadwiseReceipt(2, "f2")))

        assertEquals(mapOf("x" to ReadwiseReceipt(1, "f1")), owner.receipts("account-a"))
        assertEquals(mapOf("x" to ReadwiseReceipt(2, "f2")), owner.receipts("account-b"))
        assertTrue(child.receipts("account-a").isEmpty())
        assertEquals(mapOf("x" to ReadwiseReceipt(1, "f1")), ReadwiseReceiptStore(locations(root)).receipts("account-a"))
    }

    @Test fun receiptUpdatesReplaceTheFingerprintAndKeepOtherHighlights() = runBlocking {
        val root = folder.newFolder()
        val store = ReadwiseReceiptStore(locations(root))

        store.record("account", mapOf("a" to ReadwiseReceipt(1, "old"), "b" to ReadwiseReceipt(2, "b")))
        store.record("account", mapOf("a" to ReadwiseReceipt(1, "new")))

        assertEquals(
            mapOf("a" to ReadwiseReceipt(1, "new"), "b" to ReadwiseReceipt(2, "b")),
            ReadwiseReceiptStore(locations(root)).receipts("account"),
        )
    }

    @Test fun corruptReceiptFileStartsEmpty() = runBlocking {
        val root = folder.newFolder()
        File(root, "files/readwise").mkdirs()
        File(root, "files/readwise/receipts.json").writeText("{not json")
        val store = ReadwiseReceiptStore(locations(root))

        assertTrue(store.receipts("account").isEmpty())
        store.record("account", mapOf("a" to ReadwiseReceipt(3, "f")))
        assertEquals(mapOf("a" to ReadwiseReceipt(3, "f")), ReadwiseReceiptStore(locations(root)).receipts("account"))
    }

    @Test fun tokensAreNormalizedAtTheBoundary() {
        assertEquals("abc123", normalizedReadwiseToken("  abc123 \n"))
        assertEquals("abc123", normalizedReadwiseToken("Token abc123"))
        assertNull(normalizedReadwiseToken("   "))
        assertNull(normalizedReadwiseToken("abc 123"))
        assertNull(normalizedReadwiseToken("abc\r\nX-Evil: 1"))
        assertNull(normalizedReadwiseToken("tökén"))
    }

    private fun annotation(
        id: String,
        selectedText: String = "",
        note: String = "",
        kind: AnnotationKind = AnnotationKind.HIGHLIGHT,
        media: AnnotationMedia = AnnotationMedia.EPUB,
        deletedAt: Long? = null,
        pdfPage: Int? = null,
        cbzPage: Int? = null,
        audioPositionMs: Long? = null,
        progression: Double? = null,
        totalProgression: Double? = null,
        createdAt: Long = 1_000L,
    ) = ReaderAnnotation(
        id = id,
        bookId = "b1",
        kind = kind.name,
        media = media.name,
        selectedText = selectedText,
        note = note,
        deletedAt = deletedAt,
        pdfPage = pdfPage,
        cbzPage = cbzPage,
        audioPositionMs = audioPositionMs,
        progression = progression,
        totalProgression = totalProgression,
        createdAt = createdAt,
        updatedAt = createdAt,
    )
}
