package com.enve.app.data.opds

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.ReaderEngineKind
import com.enve.core.reader.ReaderTextQuote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsProgressionSnapshotTest {

    private val audiobook = Book(
        id = "urn:uuid:book",
        title = "Moby-Dick",
        source = BookSource.OPDS,
        mediaType = AppMediaType.AUDIOBOOK,
        duration = 3_600L,
    )

    private val ebook = audiobook.copy(mediaType = AppMediaType.EBOOK, duration = 0L)

    @Test
    fun falls_back_to_the_numeric_progression_when_there_are_no_references() {
        val snapshot = document(progression = 0.5).toSnapshot(audiobook)

        assertEquals(0.5f, snapshot.percentage, 1e-6f)
        assertEquals(1_800_000L, snapshot.positionMs)
        assertNull(snapshot.locatorJson)
        assertNull(snapshot.href)
        assertNull(snapshot.epubCfi)
        assertEquals(BookSource.OPDS.displayName, snapshot.source)
    }

    @Test
    fun prefers_the_audio_media_fragment_over_the_derived_position() {
        val snapshot = document(progression = 0.5, references = listOf("#t=849.250")).toSnapshot(audiobook)

        assertEquals(849_250L, snapshot.positionMs)
    }

    @Test
    fun maps_references_onto_a_locator_the_readers_can_restore() {
        val cfi = "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10)"
        val snapshot = document(
            progression = 0.0174920,
            references = listOf(
                "chapter1.html#:~:text=It%20was%20expected",
                OpdsProgressionReferences.cfi(null, cfi).raw,
            ),
        ).toSnapshot(ebook)

        assertNull(snapshot.positionMs)
        assertEquals("chapter1.html", snapshot.href)
        assertEquals(cfi, snapshot.epubCfi)
        val locator = snapshot.locatorJson
        requireNotNull(locator)
        assertTrue(locator.contains("\"href\":\"chapter1.html\""))
        assertTrue(locator.contains("\"highlight\":\"It was expected\""))
        assertTrue(locator.contains("\"cfi\":\"$cfi\""))
    }

    @Test
    fun carries_a_pdf_page_into_the_locator_shape_the_readers_parse() {
        val snapshot = document(progression = 0.048204, references = listOf("#page=87")).toSnapshot(ebook)

        assertTrue(snapshot.locatorJson!!.contains("\"page\":87"))
    }

    @Test
    fun marks_a_completed_publication_as_finished() {
        assertTrue(document(progression = 1.0).toSnapshot(ebook).finished)
        assertFalse(document(progression = 0.5).toSnapshot(ebook).finished)
    }

    @Test
    fun orders_references_from_the_media_fragment_to_the_opaque_cfi() {
        val anchor = OpdsLocalAnchor(
            resource = "chapter1.html",
            cfi = "epubcfi(/6/4!/4/2)",
            quote = "It was expected",
        )

        val references = opdsProgressionReferences(AppMediaType.AUDIOBOOK, 40L, anchor, null)

        assertEquals(
            listOf(
                "#t=40",
                "chapter1.html#:~:text=It%20was%20expected",
                "chapter1.html#epubcfi(/6/4!/4/2)",
            ),
            references.map { it.raw },
        )
    }

    @Test
    fun omits_the_media_fragment_for_ebooks_and_adds_the_pdf_page() {
        val references = opdsProgressionReferences(
            mediaType = AppMediaType.EBOOK,
            currentTimeSec = 99L,
            anchor = OpdsLocalAnchor(fragmentId = "par36"),
            page = 6,
        )

        assertEquals(listOf("#par36", "#page=6"), references.map { it.raw })
    }

    @Test
    fun exposes_the_references_no_reader_can_rebuild() {
        val document = document(
            progression = 0.5,
            references = listOf("#t=5", "chapter1.html#par36", "#xywh=160,120,320,240", "page78.jxl"),
        )

        assertEquals(listOf("#xywh=160,120,320,240"), document.unhandledReferences)
    }

    @Test
    fun carried_references_follow_the_generated_ones_in_their_stored_order() {
        val generated = opdsProgressionReferences(
            mediaType = AppMediaType.AUDIOBOOK,
            currentTimeSec = 40L,
            anchor = OpdsLocalAnchor(resource = "chapter1.html"),
            page = null,
        )

        val merged = mergeProgressionReferences(
            generated = generated,
            carried = listOf("#xywh=160,120,320,240", "cover.jpg#xywh=0,0,10,10"),
        )

        assertEquals(
            listOf("#t=40", "chapter1.html", "#xywh=160,120,320,240", "cover.jpg#xywh=0,0,10,10"),
            merged.map { it.raw },
        )
    }

    @Test
    fun a_carried_reference_is_never_written_twice() {
        val generated = opdsProgressionReferences(
            mediaType = AppMediaType.EBOOK,
            currentTimeSec = null,
            anchor = OpdsLocalAnchor(fragmentId = "par36"),
            page = 6,
        )

        val merged = mergeProgressionReferences(
            generated = generated,
            carried = listOf("#page=6", "#xywh=160,120,320,240", "#xywh=160,120,320,240"),
        )

        assertEquals(listOf("#par36", "#page=6", "#xywh=160,120,320,240"), merged.map { it.raw })
    }

    @Test
    fun reads_a_readium_locator() {
        val anchor = readOpdsLocalAnchor(
            """
            {
              "href": "chapter1.html",
              "type": "application/xhtml+xml",
              "title": "Chapter 1",
              "locations": { "fragments": ["par36"], "totalProgression": 0.12 },
              "text": { "highlight": "It was expected" }
            }
            """.trimIndent(),
        )

        assertEquals("chapter1.html", anchor.resource)
        assertEquals("par36", anchor.fragmentId)
        assertEquals("It was expected", anchor.quote)
        assertEquals("Chapter 1", anchor.title)
        assertNull(anchor.cfi)
    }

    @Test
    fun reads_a_reader_bridge_checkpoint() {
        val encoded = EpubBridgeCheckpointCodec.encode(
            EpubBridgeCheckpoint(
                publicationSha256 = "sha",
                observedAt = 1L,
                sourceEngine = ReaderEngineKind.FOLIATE,
                href = "chapter1.html",
                epubCfi = "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10)",
                textQuote = ReaderTextQuote(exact = "It was expected"),
            ),
        )

        val anchor = readOpdsLocalAnchor(encoded)

        assertEquals("chapter1.html", anchor.resource)
        assertEquals("epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10)", anchor.cfi)
        assertEquals("It was expected", anchor.quote)
    }

    @Test
    fun carries_a_saved_page_locator_back_into_a_page_reference() {
        val anchor = readOpdsLocalAnchor("""{"page":12}""")

        assertEquals(12, anchor.page)
        assertEquals(
            listOf("#page=12"),
            opdsProgressionReferences(AppMediaType.EBOOK, null, anchor, null).map { it.raw },
        )
    }

    @Test
    fun ignores_locators_that_are_not_json() {
        assertEquals(OpdsLocalAnchor(), readOpdsLocalAnchor("cbz-page:12"))
        assertEquals(OpdsLocalAnchor(), readOpdsLocalAnchor(null))
    }

    private fun document(progression: Double, references: List<String> = emptyList()) =
        OpdsProgressionDocument.at(
            modifiedAtMs = 1_700_000_000_000L,
            device = OpdsProgressionDevice("urn:uuid:device", "Enve"),
            progression = progression,
            references = references.map(OpdsProgressionReferences::parse),
        )
}
