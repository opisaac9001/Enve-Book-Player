package com.enve.app.data.hardcover

import com.enve.core.data.model.AppMediaType
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HardcoverIdentifiersTest {
    private val print = HardcoverEdition(id = 1, pages = 412, audioSeconds = null)
    private val audio = HardcoverEdition(id = 2, pages = null, audioSeconds = 75_600)

    private fun edition(
        edition: HardcoverEdition,
        bookId: Int = 100,
        isbn10: String? = null,
        isbn13: String? = null,
        asin: String? = null,
    ) = HardcoverIdentifiedEdition(edition, bookId, "Dune", isbn10, isbn13, asin)

    @Test fun isbnsAreNormalizedAndChecksummed() {
        assertEquals(HardcoverIdentifiers(isbn13 = "9780441172719"), hardcoverIdentifiers("978-0-441-17271-9"))
        assertEquals(HardcoverIdentifiers(isbn13 = "9780441172719"), hardcoverIdentifiers("ISBN-13: 978 0441172719"))
        assertEquals(HardcoverIdentifiers(isbn10 = "0441172717"), hardcoverIdentifiers("0-441-17271-7"))
        assertEquals(HardcoverIdentifiers(isbn10 = "080442957X"), hardcoverIdentifiers("080442957x"))
        assertTrue(hardcoverIdentifiers("9780441172718").isEmpty)
        assertTrue(hardcoverIdentifiers("0441172718").isEmpty)
        assertTrue(hardcoverIdentifiers("1234567890128").isEmpty)
        assertTrue(hardcoverIdentifiers("not an isbn").isEmpty)
        assertTrue(hardcoverIdentifiers(null).isEmpty)
    }

    @Test fun asinIsOnlyAcceptedInItsAmazonShape() {
        assertEquals(HardcoverIdentifiers(asin = "B0036S4B7E"), hardcoverIdentifiers("b0036s4b7e"))
        assertTrue(hardcoverIdentifiers("B0036S4B7").isEmpty)
        assertTrue(hardcoverIdentifiers("A0036S4B7E").isEmpty)
    }

    @Test fun multipleIdentifierHitsRequireManualEditionChoice() {
        val identifiers = HardcoverIdentifiers(isbn13 = "9780441172719")
        val match = hardcoverIdentifierMatch(
            identifiers,
            listOf(edition(print, isbn13 = "978-0441172719"), edition(audio, isbn13 = "9780441172719")),
        )
        assertEquals(HardcoverIdentifierMatch.Conflict, match)
    }

    @Test fun singleHitIsKeptEvenWhenItsLengthIsForAnotherMedium() {
        val match = hardcoverIdentifierMatch(
            HardcoverIdentifiers(isbn10 = "0441172717"),
            listOf(edition(print, isbn10 = "0441172717")),
        )
        assertEquals(HardcoverIdentifierMatch.Matched(100, "Dune", print), match)
    }

    @Test fun ambiguousEditionsRequireManualChoice() {
        val match = hardcoverIdentifierMatch(
            HardcoverIdentifiers(isbn13 = "9780441172719"),
            listOf(edition(print, isbn13 = "9780441172719"), edition(print.copy(id = 3), isbn13 = "9780441172719")),
        )
        assertEquals(HardcoverIdentifierMatch.Conflict, match)
    }

    @Test fun identifierSharedByDifferentBooksIsAConflict() {
        val match = hardcoverIdentifierMatch(
            HardcoverIdentifiers(isbn13 = "9780441172719"),
            listOf(edition(print, bookId = 100, isbn13 = "9780441172719"), edition(audio, bookId = 200, isbn13 = "9780441172719")),
        )
        assertEquals(HardcoverIdentifierMatch.Conflict, match)
    }

    @Test fun contradictoryIdentifiersOnTheMatchedEditionAreAConflict() {
        val match = hardcoverIdentifierMatch(
            HardcoverIdentifiers(isbn13 = "9780441172719", asin = "B0036S4B7E"),
            listOf(edition(audio, isbn13 = "9780441172719", asin = "B00B7NPRY8")),
        )
        assertEquals(HardcoverIdentifierMatch.Conflict, match)
    }

    @Test fun unrelatedRowsAndEmptyIdentifiersAreNoHit() {
        val identifiers = HardcoverIdentifiers(isbn13 = "9780441172719")
        assertEquals(HardcoverIdentifierMatch.NoHit, hardcoverIdentifierMatch(identifiers, emptyList()))
        assertEquals(
            HardcoverIdentifierMatch.NoHit,
            hardcoverIdentifierMatch(identifiers, listOf(edition(print, isbn13 = "9780593099322"))),
        )
        assertEquals(
            HardcoverIdentifierMatch.NoHit,
            hardcoverIdentifierMatch(HardcoverIdentifiers(), listOf(edition(print, isbn13 = "9780441172719"))),
        )
    }

    @Test fun editionRowsParseFromGraphQl() {
        val rows = Json.parseToJsonElement(
            """[{"id":7,"book_id":9,"isbn_10":null,"isbn_13":"9780441172719","asin":null,"pages":412,"audio_seconds":null,"book":{"title":"Dune"}},
                {"id":null,"book_id":9}]""",
        ).jsonArray
        val parsed = hardcoverIdentifiedEditions(rows)
        assertEquals(1, parsed.size)
        assertEquals(HardcoverIdentifiedEdition(HardcoverEdition(7, 412, null), 9, "Dune", null, "9780441172719", null), parsed.single())
        assertNull(parsed.single().asin)
    }

    @Test fun selectedEditionDrivesProgressWhenUsableForTheMedium() {
        val selected = HardcoverEdition(id = 40, pages = 200, audioSeconds = null)
        val state = HardcoverBookState(
            userBook = HardcoverUserBookState(
                id = 5,
                statusId = 2,
                edition = null,
                reads = listOf(HardcoverRead(9, null, null, null, HardcoverEdition(11, 400, null))),
            ),
            defaultAudioEdition = null,
            defaultEbookEdition = HardcoverEdition(11, 400, null),
            defaultPhysicalEdition = null,
            selectedEdition = selected,
        )
        assertEquals(
            HardcoverSyncPlan.WriteProgress(readId = 9, editionId = 40, pages = 100, seconds = null),
            hardcoverSyncPlan(state, AppMediaType.EBOOK, 0.5f, finished = false),
        )
        assertEquals(
            HardcoverSyncPlan.NeedsEdition("The selected Hardcover edition has no page count or audio length."),
            hardcoverSyncPlan(state.copy(selectedEdition = selected.copy(pages = null)), AppMediaType.EBOOK, 0.5f, finished = false),
        )
        assertEquals(
            HardcoverSyncPlan.AddToLibrary(statusId = 2, editionId = 40),
            hardcoverSyncPlan(state.copy(userBook = null), AppMediaType.EBOOK, 0.5f, finished = false),
        )
    }
}
