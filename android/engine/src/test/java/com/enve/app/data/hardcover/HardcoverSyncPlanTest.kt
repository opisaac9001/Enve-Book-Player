package com.enve.app.data.hardcover

import com.enve.core.data.model.AppMediaType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HardcoverSyncPlanTest {
    private val ebookEdition = HardcoverEdition(id = 11, pages = 400, audioSeconds = null)
    private val audioEdition = HardcoverEdition(id = 12, pages = null, audioSeconds = 36_000)

    private fun state(userBook: HardcoverUserBookState?) = HardcoverBookState(
        userBook = userBook,
        defaultAudioEdition = audioEdition,
        defaultEbookEdition = ebookEdition,
        defaultPhysicalEdition = null,
    )

    private fun userBook(statusId: Int, vararg reads: HardcoverRead, edition: HardcoverEdition? = null) =
        HardcoverUserBookState(id = 5, statusId = statusId, edition = edition, reads = reads.toList())

    private fun read(id: Int, finishedAt: String? = null, pages: Int? = null, seconds: Int? = null, edition: HardcoverEdition? = null) =
        HardcoverRead(id, finishedAt, pages, seconds, edition)

    @Test fun missingLibraryRowAddsCurrentlyReadingWithMediumDefaultEdition() {
        assertEquals(
            HardcoverSyncPlan.AddToLibrary(statusId = 2, editionId = 12),
            hardcoverSyncPlan(state(null), AppMediaType.AUDIOBOOK, 0.3f, finished = false),
        )
        assertEquals(
            HardcoverSyncPlan.AddToLibrary(statusId = 1, editionId = 11),
            hardcoverSyncPlan(state(null), AppMediaType.EBOOK, 1f, finished = true),
        )
    }

    @Test fun audiobookProgressUsesSelectedEditionSeconds() {
        val plan = hardcoverSyncPlan(
            state(userBook(2, read(9, edition = audioEdition))),
            AppMediaType.AUDIOBOOK,
            0.5f,
            finished = false,
        )
        assertEquals(HardcoverSyncPlan.WriteProgress(readId = 9, editionId = 12, pages = null, seconds = 18_000), plan)
    }

    @Test fun audioFractionUsesSelectedPrintEditionWithoutChangingIt() {
        val plan = hardcoverSyncPlan(
            state(userBook(2, read(9), edition = ebookEdition)),
            AppMediaType.AUDIOBOOK,
            0.5f,
            finished = false,
        )
        assertEquals(HardcoverSyncPlan.WriteProgress(readId = 9, editionId = 11, pages = 200, seconds = null), plan)
    }

    @Test fun progressNeverRoundsUpToAnImplicitFinish() {
        val plan = hardcoverSyncPlan(state(userBook(2, read(9, edition = ebookEdition))), AppMediaType.EBOOK, 0.9999f, finished = false)
        assertEquals(399, (plan as HardcoverSyncPlan.WriteProgress).pages)
    }

    @Test fun unchangedOrBackwardProgressDoesNotWrite() {
        val reading = state(userBook(2, read(9, pages = 200, edition = ebookEdition)))
        assertEquals(HardcoverSyncPlan.UpToDate, hardcoverSyncPlan(reading, AppMediaType.EBOOK, 0.5f, finished = false))
        assertTrue(hardcoverSyncPlan(reading, AppMediaType.EBOOK, 0.2f, finished = false) is HardcoverSyncPlan.Skip)
    }

    @Test fun finishHappensOnce() {
        val reading = state(userBook(2, read(9, pages = 300, edition = ebookEdition)))
        assertEquals(HardcoverSyncPlan.FinishRead(5, 9), hardcoverSyncPlan(reading, AppMediaType.EBOOK, 1f, finished = true))
        val finished = state(userBook(3, read(9, finishedAt = "2026-10-01", pages = 400, edition = ebookEdition)))
        assertEquals(HardcoverSyncPlan.AlreadyFinished, hardcoverSyncPlan(finished, AppMediaType.EBOOK, 1f, finished = true))
    }

    @Test fun finishedBookIsNotReopenedByStaleProgress() {
        val finished = state(userBook(3, read(9, finishedAt = "2026-10-01", pages = 400, edition = ebookEdition)))
        assertTrue(hardcoverSyncPlan(finished, AppMediaType.EBOOK, 0.6f, finished = false) is HardcoverSyncPlan.Skip)
    }

    @Test fun reReadStartsNewReadAndKeepsHistory() {
        val finished = state(userBook(3, read(9, finishedAt = "2026-10-01", pages = 400, edition = ebookEdition)))
        assertEquals(HardcoverSyncPlan.SetStatus(5, 2), hardcoverSyncPlan(finished, AppMediaType.EBOOK, 0.05f, finished = false))

        val reReading = state(userBook(2, read(10, edition = ebookEdition), read(9, finishedAt = "2026-10-01", pages = 400, edition = ebookEdition)))
        assertEquals(
            HardcoverSyncPlan.WriteProgress(readId = 10, editionId = 11, pages = 20, seconds = null),
            hardcoverSyncPlan(reReading, AppMediaType.EBOOK, 0.05f, finished = false),
        )
    }

    @Test fun currentlyReadingWithoutOpenReadStartsOne() {
        assertEquals(
            HardcoverSyncPlan.StartRead(5, 11),
            hardcoverSyncPlan(state(userBook(2, edition = ebookEdition)), AppMediaType.EBOOK, 0.4f, finished = false),
        )
    }

    @Test fun matchingRequiresUniqueExactTitleAndAuthor() {
        val dune = HardcoverBookResult(1, "Dune", "Frank Herbert", null, 1965, authorNames = listOf("Frank Herbert"))
        val duneMessiah = HardcoverBookResult(2, "Dune Messiah", "Frank Herbert", null, 1969, authorNames = listOf("Frank Herbert"))
        val otherDune = HardcoverBookResult(3, "Dune", "Someone Else", null, 2001, authorNames = listOf("Someone Else"))

        assertEquals(dune, hardcoverExactMatch("DUNE", "Herbert, Frank & Frank Herbert", listOf(duneMessiah, dune, otherDune)))
        assertNull(hardcoverExactMatch("Dune", null, listOf(dune)))
        assertNull(hardcoverExactMatch("Dune", "Brian Herbert", listOf(dune)))
        assertNull(hardcoverExactMatch("Dune", "Frank Herbert", listOf(dune, dune.copy(id = 4))))
        assertEquals(dune, hardcoverExactMatch("Dune", "Frank Herbert", listOf(dune, dune)))
    }

    @Test fun oldOpenReadIsNotResumedAfterLaterFinishedRead() {
        val finished = state(userBook(3,
            read(10, finishedAt = "2026-10-01", pages = 400, edition = ebookEdition),
            read(9, pages = 100, edition = ebookEdition),
        ))
        assertEquals(HardcoverSyncPlan.SetStatus(5, 2), hardcoverSyncPlan(finished, AppMediaType.EBOOK, 0.05f, false))
    }

    @Test fun matchingPreservesNonLatinTitles() {
        val first = HardcoverBookResult(1, "沙丘", "作者", null, null, authorNames = listOf("作者"))
        assertEquals(first, hardcoverExactMatch("沙丘", "作者", listOf(first)))
        assertNull(hardcoverExactMatch("另一部书", "作者", listOf(first)))
    }

    @Test fun accentsAndPunctuationNormalize() {
        assertEquals(hardcoverNormalized("Les Misérables!"), hardcoverNormalized("les miserables"))
    }
    @Test fun completionRetryAfterReadWriteOnlyUpdatesShelfStatus() {
        val readFinished = state(userBook(2, read(9, finishedAt = "2026-10-01", pages = 400, edition = ebookEdition)))
        assertEquals(HardcoverSyncPlan.SetStatus(5, 3), hardcoverSyncPlan(readFinished, AppMediaType.EBOOK, 1f, true))
    }

    @Test fun coalescedOfflineRereadRetainsItsStartNearTheBeginning() {
        val finished = state(userBook(3, read(9, finishedAt = "2026-10-01", edition = ebookEdition)))
        assertEquals(HardcoverSyncPlan.SetStatus(5, 2),
            hardcoverSyncPlan(finished, AppMediaType.EBOOK, 0.8f, false, initialFraction = 0.02f))
    }

}
