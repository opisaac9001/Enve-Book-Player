package com.enve.silo

import com.enve.silo.dto.SiloCollection
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SiloCatalogCursors @Inject constructor() {
    private class Listing {
        val mutex = Mutex()
        val starts = mutableMapOf<Int, SiloPageStart?>(0 to SiloPageStart(null))
    }

    private val listings = ConcurrentHashMap<String, Listing>()

    internal suspend fun <T> page(
        listingKey: String,
        page: Int,
        size: Int,
        fetch: suspend (cursor: String?) -> SiloCollection<T>,
    ): List<T> {
        val listing = listings.getOrPut(listingKey, ::Listing)
        return listing.mutex.withLock {
            if (page == 0) listing.starts.keys.retainAll(setOf(0))
            var index = listing.starts.keys.filter { it <= page }.max()
            var items = emptyList<T>()
            while (index <= page) {
                val start = listing.starts[index] ?: return@withLock emptyList()
                val window = siloFillPage(start, size, fetch)
                listing.starts[index + 1] = window.next
                items = window.items
                index += 1
            }
            items
        }
    }

    fun clear() = listings.clear()
}
