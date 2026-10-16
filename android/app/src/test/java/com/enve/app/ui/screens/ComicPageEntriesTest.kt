package com.enve.app.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test

class ComicPageEntriesTest {
    @Test
    fun emptyBookHasNoEntries() {
        assertEquals(emptyList<List<Int>>(), buildPageEntries(0, spreadActive = true, widePages = emptySet()))
        assertEquals(emptyList<List<Int>>(), buildPageEntries(0, spreadActive = false, widePages = emptySet()))
    }

    @Test
    fun singlePageBookShowsTheCoverAlone() {
        assertEquals(listOf(listOf(0)), buildPageEntries(1, spreadActive = true, widePages = emptySet()))
    }

    @Test
    fun coverStaysAloneAndLaterPagesPair() {
        assertEquals(
            listOf(listOf(0), listOf(1, 2), listOf(3, 4)),
            buildPageEntries(5, spreadActive = true, widePages = emptySet()),
        )
    }

    @Test
    fun evenCountLeavesTheFinalPageAlone() {
        assertEquals(
            listOf(listOf(0), listOf(1, 2), listOf(3, 4), listOf(5)),
            buildPageEntries(6, spreadActive = true, widePages = emptySet()),
        )
    }

    @Test
    fun twoPageBookKeepsBothPagesSeparate() {
        assertEquals(listOf(listOf(0), listOf(1)), buildPageEntries(2, spreadActive = true, widePages = emptySet()))
    }

    @Test
    fun middleWidePageStandsAloneAndRealignsLaterPairs() {
        assertEquals(
            listOf(listOf(0), listOf(1, 2), listOf(3), listOf(4, 5), listOf(6)),
            buildPageEntries(7, spreadActive = true, widePages = setOf(3)),
        )
        assertEquals(
            listOf(listOf(0), listOf(1), listOf(2), listOf(3, 4), listOf(5, 6)),
            buildPageEntries(7, spreadActive = true, widePages = setOf(2)),
        )
    }

    @Test
    fun finalWidePageStandsAlone() {
        assertEquals(
            listOf(listOf(0), listOf(1, 2), listOf(3, 4), listOf(5)),
            buildPageEntries(6, spreadActive = true, widePages = setOf(5)),
        )
        assertEquals(
            listOf(listOf(0), listOf(1, 2), listOf(3), listOf(4)),
            buildPageEntries(5, spreadActive = true, widePages = setOf(4)),
        )
    }

    @Test
    fun widePageNeverPairsWithAPortraitNeighbour() {
        val entries = buildPageEntries(9, spreadActive = true, widePages = setOf(4, 5))
        assertEquals(
            listOf(listOf(0), listOf(1, 2), listOf(3), listOf(4), listOf(5), listOf(6, 7), listOf(8)),
            entries,
        )
        assertEquals((0 until 9).toList(), entries.flatten())
    }

    @Test
    fun singlePageModeShowsOneSourcePagePerEntry() {
        assertEquals(
            listOf(listOf(0), listOf(1), listOf(2), listOf(3), listOf(4)),
            buildPageEntries(5, spreadActive = false, widePages = setOf(2)),
        )
    }

    @Test
    fun rightToLeftSpreadPlacesTheEarlierPageOnTheRight() {
        val spread = buildPageEntries(5, spreadActive = true, widePages = emptySet())[1]
        assertEquals(listOf(2, 1), spreadDisplayOrder(spread, isRtl = true))
    }

    @Test
    fun leftToRightSpreadPlacesTheEarlierPageOnTheLeft() {
        val spread = buildPageEntries(5, spreadActive = true, widePages = emptySet())[1]
        assertEquals(listOf(1, 2), spreadDisplayOrder(spread, isRtl = false))
    }

    @Test
    fun loneEntriesKeepTheirPageInEitherDirection() {
        assertEquals(listOf(3), spreadDisplayOrder(listOf(3), isRtl = true))
        assertEquals(listOf(3), spreadDisplayOrder(listOf(3), isRtl = false))
    }

    @Test
    fun wideFirstContentPageStandsAloneAfterTheCoverAndOddCountPairsTheRest() {
        val entries = buildPageEntries(7, spreadActive = true, widePages = setOf(1))
        assertEquals(listOf(listOf(0), listOf(1), listOf(2, 3), listOf(4, 5), listOf(6)), entries)
        assertEquals((0 until 7).toList(), entries.flatten())
    }

    @Test
    fun wideCoverStillStandsAlone() {
        assertEquals(
            listOf(listOf(0), listOf(1, 2), listOf(3, 4)),
            buildPageEntries(5, spreadActive = true, widePages = setOf(0)),
        )
    }
}
