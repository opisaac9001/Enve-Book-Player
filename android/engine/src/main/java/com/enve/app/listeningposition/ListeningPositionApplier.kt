package com.enve.app.listeningposition

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.listeningposition.ListeningPositionPayload
import com.enve.core.listeningposition.SharedReadingLocation
import com.enve.engine.listeningposition.ListeningPositionApplyResult
import com.enve.engine.listeningposition.ListeningPositionServerStatus
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

interface ListeningPositionProgressTarget {
    suspend fun <T> ordered(book: Book, action: suspend () -> T): T
    suspend fun reload(book: Book): Book
    suspend fun seekIfLoaded(book: Book, positionMilliseconds: Long)
    suspend fun save(book: Book, positionMilliseconds: Long): Book
    suspend fun saveReading(book: Book, location: SharedReadingLocation): Book
    suspend fun push(book: Book): ListeningPositionServerStatus
}

class ListeningPositionApplier(private val target: ListeningPositionProgressTarget) {
    private val mutexes = ConcurrentHashMap<String, Mutex>()

    suspend fun apply(payload: ListeningPositionPayload, selection: Book): ListeningPositionApplyResult =
        mutexes.getOrPut(selection.uniqueKey) { Mutex() }.withLock {
            target.ordered(selection) {
                val book = target.reload(selection)
                val reading = payload.readingLocation
                require((reading != null) == (book.mediaType == AppMediaType.EBOOK)) { "Choose a copy in the same media format as the shared position." }
                val updated = if (reading != null) {
                    require(reading.page == null || reading.format != SharedReadingLocation.format(book) ||
                        (book.pageCount ?: 0) <= 0 || reading.page!! <= book.pageCount!!) { "The shared page is past the end of this copy." }
                    target.saveReading(book, reading)
                } else {
                    require(book.duration <= 0 || payload.positionMilliseconds / 1000.0 <= book.duration) { "The shared time is past the end of this copy." }
                    target.seekIfLoaded(book, payload.positionMilliseconds)
                    target.save(book, payload.positionMilliseconds)
                }
                ListeningPositionApplyResult(updated, payload.positionMilliseconds, target.push(updated), reading)
            }
        }
}
