package com.enve.audiobookshelf

import com.enve.audiobookshelf.dto.AbsLibraryItemDto
import com.enve.audiobookshelf.dto.AbsMediaProgressDto
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AbsMediaProgressMergeTest {

    @Test
    fun attachesAccountProgressToInProgressItems() {
        val items = listOf(
            AbsLibraryItemDto(id = "started"),
            AbsLibraryItemDto(id = "unmatched"),
        )
        val progress = AbsMediaProgressDto(
            libraryItemId = "started",
            progress = 0.42f,
            currentTime = 1_234.0,
            lastUpdate = 456L,
        )

        val merged = mergeAbsMediaProgress(items, listOf(progress))

        assertEquals(progress, merged[0].mediaProgress)
        assertNull(merged[1].mediaProgress)
    }

    @Test
    fun preservesInlineProgressWhenAccountEntryIsUnavailable() {
        val inline = AbsMediaProgressDto(
            libraryItemId = "inline",
            progress = 0.25f,
        )
        val item = AbsLibraryItemDto(
            id = "inline",
            mediaProgress = inline,
        )

        val merged = mergeAbsMediaProgress(listOf(item), emptyList())

        assertEquals(inline, merged.single().mediaProgress)
    }
}
