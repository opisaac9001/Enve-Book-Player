package com.enve.core.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PdfReadingLayoutTest {
    private val single = PdfReadingLayout()
    private val paired = PdfReadingLayout(twoPageView = true)
    private val coverApart = PdfReadingLayout(twoPageView = true, showCoverSeparately = true)

    @Test
    fun bothOptionsDefaultOff() {
        assertFalse(single.twoPageView)
        assertFalse(single.showCoverSeparately)
        assertFalse(single.coverStandsAlone)
    }

    @Test
    fun coverSeparatelyOnlyTakesEffectWithTwoPageView() {
        val layout = PdfReadingLayout(showCoverSeparately = true)
        assertFalse(layout.coverStandsAlone)
        assertEquals(listOf(0, 1, 2, 3, 4, 5), (0 until 6).map { layout.spreadContaining(it, 6).first })
    }

    @Test
    fun singlePageLayoutShowsOnePageAtATime() {
        for (page in 0 until 6) assertEquals(PdfSpread(page, page), single.spreadContaining(page, 6))
    }

    @Test
    fun twoPageViewPairsFromTheFirstPageForEvenCounts() {
        assertEquals(listOf(PdfSpread(0, 1), PdfSpread(2, 3), PdfSpread(4, 5)), spreads(paired, 6))
    }

    @Test
    fun twoPageViewLeavesTheFinalPageAloneForOddCounts() {
        assertEquals(listOf(PdfSpread(0, 1), PdfSpread(2, 3), PdfSpread(4, 4)), spreads(paired, 5))
    }

    @Test
    fun showingTheCoverSeparatelyPairsFromTheSecondPage() {
        assertEquals(listOf(PdfSpread(0, 0), PdfSpread(1, 2), PdfSpread(3, 4), PdfSpread(5, 5)), spreads(coverApart, 6))
        assertEquals(listOf(PdfSpread(0, 0), PdfSpread(1, 2), PdfSpread(3, 4)), spreads(coverApart, 5))
    }

    @Test
    fun everyPageMapsToTheSpreadThatContainsIt() {
        for (pageCount in 1..9) {
            for (layout in listOf(single, paired, coverApart)) {
                for (page in 0 until pageCount) {
                    val spread = layout.spreadContaining(page, pageCount)
                    assertTrue("$layout page $page of $pageCount gave $spread", page in spread.pages)
                    assertTrue(spread.last < pageCount)
                }
            }
        }
    }

    @Test
    fun outOfRangePagesClampToTheDocument() {
        assertEquals(PdfSpread(0, 1), paired.spreadContaining(-3, 6))
        assertEquals(PdfSpread(4, 5), paired.spreadContaining(42, 6))
        assertEquals(PdfSpread(5, 5), coverApart.spreadContaining(42, 6))
        assertEquals(PdfSpread(0, 0), paired.spreadContaining(0, 1))
        assertEquals(PdfSpread(0, 0), coverApart.spreadContaining(7, 1))
    }

    @Test
    fun forwardTurnsStepWholeSpreadsAndSelectTheLastPageOfTheSpread() {
        assertEquals(3, paired.pageAfterTurningForward(0, 6))
        assertEquals(3, paired.pageAfterTurningForward(1, 6))
        assertEquals(5, paired.pageAfterTurningForward(3, 6))
        assertNull(paired.pageAfterTurningForward(4, 6))
        assertNull(paired.pageAfterTurningForward(5, 6))

        assertEquals(2, coverApart.pageAfterTurningForward(0, 6))
        assertEquals(4, coverApart.pageAfterTurningForward(1, 6))
        assertEquals(5, coverApart.pageAfterTurningForward(4, 6))
        assertNull(coverApart.pageAfterTurningForward(5, 6))

        assertEquals(1, single.pageAfterTurningForward(0, 6))
        assertNull(single.pageAfterTurningForward(5, 6))
    }

    @Test
    fun backwardTurnsStepWholeSpreadsAndStopAtTheFirstPage() {
        assertEquals(1, paired.pageAfterTurningBackward(3, 6))
        assertEquals(1, paired.pageAfterTurningBackward(2, 6))
        assertEquals(3, paired.pageAfterTurningBackward(5, 6))
        assertNull(paired.pageAfterTurningBackward(0, 6))
        assertNull(paired.pageAfterTurningBackward(1, 6))

        assertEquals(0, coverApart.pageAfterTurningBackward(1, 6))
        assertEquals(0, coverApart.pageAfterTurningBackward(2, 6))
        assertEquals(2, coverApart.pageAfterTurningBackward(3, 6))
        assertEquals(4, coverApart.pageAfterTurningBackward(5, 6))
        assertNull(coverApart.pageAfterTurningBackward(0, 6))

        assertEquals(0, single.pageAfterTurningBackward(1, 6))
        assertNull(single.pageAfterTurningBackward(0, 6))
    }

    @Test
    fun theFinalSpreadIsReachableByTurningForwardFromTheStart() {
        for (pageCount in 1..9) {
            for (layout in listOf(single, paired, coverApart)) {
                var page = 0
                var turns = 0
                while (true) {
                    page = layout.pageAfterTurningForward(page, pageCount) ?: break
                    turns++
                }
                assertEquals(pageCount - 1, layout.spreadContaining(page, pageCount).last)
                assertEquals(spreads(layout, pageCount).size - 1, turns)
            }
        }
    }

    @Test
    fun changingLayoutKeepsTheSelectedPageInsideTheNewSpread() {
        for (page in 0 until 6) {
            for (from in listOf(single, paired, coverApart)) {
                for (to in listOf(single, paired, coverApart)) {
                    val before = from.spreadContaining(page, 6)
                    val after = to.spreadContaining(page, 6)
                    assertTrue("$from -> $to lost page $page", page in before.pages && page in after.pages)
                }
            }
        }
        assertEquals(PdfSpread(0, 1), paired.spreadContaining(0, 6))
        assertEquals(PdfSpread(0, 0), coverApart.spreadContaining(0, 6))
        assertEquals(PdfSpread(2, 2), single.spreadContaining(2, 6))
        assertEquals(PdfSpread(2, 3), paired.spreadContaining(2, 6))
        assertEquals(PdfSpread(1, 2), coverApart.spreadContaining(2, 6))
    }

    private fun spreads(layout: PdfReadingLayout, pageCount: Int): List<PdfSpread> {
        val result = mutableListOf(layout.spreadContaining(0, pageCount))
        while (true) {
            result += layout.nextSpread(result.last(), pageCount) ?: break
        }
        return result
    }
}
