package com.enve.hearth.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LibraryFilterStateTest {
    @Test
    fun browsingScopeHasNoContentFilters() {
        assertEquals(0, libraryActiveFilterCount(StatusFilter.ALL, MediaFilter.ALL, LibraryAdvancedFilters()))
    }

    @Test
    fun contentFiltersCountEachSelectedConstraint() {
        assertEquals(8, libraryActiveFilterCount(
            StatusFilter.CURRENTLY_READING,
            MediaFilter.EBOOKS,
            LibraryAdvancedFilters(setOf("Fantasy", "Adventure"), setOf("English", "French"), 4f, SeriesFilter.IN_SERIES),
        ))
    }

    @Test
    fun removingTheFinalSortSurvivesPersistence() {
        val removed = DEFAULT_SORT.filterNot { it.field == LibrarySort.RECENT }
        assertTrue(decodeSortStack(encodeSortStack(removed)).isEmpty())
        val replacement = listOf(SortDescriptor(LibrarySort.TITLE, SortDirection.ASCENDING))
        assertEquals(replacement, decodeSortStack(encodeSortStack(removed + replacement)))
    }

    @Test
    fun sortRemovalPreservesRemainingPriorityAndDirection() {
        val stack = listOf(
            SortDescriptor(LibrarySort.AUTHOR_SURNAME, SortDirection.DESCENDING),
            SortDescriptor(LibrarySort.TITLE, SortDirection.ASCENDING),
            SortDescriptor(LibrarySort.DURATION, SortDirection.DESCENDING),
        )
        assertEquals(listOf(stack[0], stack[2]), decodeSortStack(encodeSortStack(stack.filterNot { it.field == LibrarySort.TITLE })))
        assertEquals(DEFAULT_SORT, decodeSortStack(""))
        assertEquals(DEFAULT_SORT, decodeSortStack("UNKNOWN:INVALID"))
    }
}
