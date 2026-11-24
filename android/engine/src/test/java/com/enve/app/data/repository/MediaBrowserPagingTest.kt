package com.enve.app.data.repository

import com.enve.app.data.remote.dto.MediaBrowserItemDto
import com.enve.app.data.remote.dto.MediaBrowserItemsDto
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MediaBrowserPagingTest {
    private val items = (1..201).map { MediaBrowserItemDto(it.toString(), type = "Book") }

    @Test fun readsEveryPageAtItsReturnedOffset() = runBlocking {
        val offsets = mutableListOf<Int>()
        val books = mediaBrowserPages { start ->
            offsets += start
            MediaBrowserItemsDto(items.drop(start).take(100), items.size)
        }
        assertEquals(listOf(0, 100, 200), offsets)
        assertEquals(items, books)
    }

    @Test fun refusesAPartialCatalogWhenTheNextPageIsEmpty() {
        assertThrows(IllegalStateException::class.java) {
            runBlocking {
                mediaBrowserPages { start ->
                    MediaBrowserItemsDto(if (start == 0) items.take(100) else emptyList(), items.size)
                }
            }
        }
    }
}
