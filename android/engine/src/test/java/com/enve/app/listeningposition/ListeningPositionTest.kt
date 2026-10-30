package com.enve.app.listeningposition

import com.enve.core.data.model.*
import com.enve.core.listeningposition.ListeningPositionPayload
import com.enve.core.listeningposition.SharedReadingLocation
import com.enve.engine.listeningposition.ListeningPositionServerStatus
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.async
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.yield
import org.junit.Assert.*
import org.junit.Test

class ListeningPositionTest {
    private val payload = ListeningPositionPayload(90000, 3600000, "A Book", listOf("An Author"), listOf("A Narrator"))
    private val book = Book("1", "A Book", author = "An Author", narrator = "A Narrator", duration = 3600, currentTime = 900, connectionId = "one")

    @Test fun ranksRecordingAndKeepsAccountsDistinct() {
        val same = book.copy(connectionId = "two")
        val otherRecording = book.copy(id = "other", duration = 7200, narrator = "Another Narrator")
        val results = ListeningPositionMatcher.rank(listOf(otherRecording, book, same, book), payload)
        assertEquals(3, results.size)
        assertTrue(results.take(2).all { it.book.id == "1" && it.warnings.isEmpty() })
        assertTrue(results.last().warnings.size >= 2)
        assertTrue(results.all { it.hasCredibleIdentity })
    }

    @Test fun identifiesWrongBookAndBlocksTimeBeyondEnd() {
        val candidate = ListeningPositionMatcher.evaluate(book.copy(title = "Unrelated", author = "Someone Else", duration = 30), payload)
        assertFalse(candidate.hasCredibleIdentity)
        assertFalse(candidate.canApply)
        assertTrue(candidate.warnings.any { it.contains("past the end") })
    }

    @Test fun applySeeksBeforeSavingAndPropagatesQueueStatus() = runBlocking {
        val calls = mutableListOf<String>()
        val target = object : ListeningPositionProgressTarget {
            override suspend fun <T> ordered(book: Book, action: suspend () -> T): T = action()
            override suspend fun reload(book: Book) = book
            override suspend fun saveReading(book: Book, location: SharedReadingLocation): Book = book.copy(
                epubProgress = location.progressionFor(book), readProgress = location.progressionFor(book), epubLocator = location.locatorFor(book))
            override suspend fun seekIfLoaded(book: Book, positionMilliseconds: Long) { calls += "seek:$positionMilliseconds" }
            override suspend fun save(book: Book, positionMilliseconds: Long): Book { calls += "save"; return book.copy(currentTime = positionMilliseconds / 1000) }
            override suspend fun push(book: Book): ListeningPositionServerStatus { calls += "push"; return ListeningPositionServerStatus.QUEUED }
        }
        val applier = ListeningPositionApplier(target)
        val result = applier.apply(payload, book)
        assertEquals(listOf("seek:90000", "save", "push"), calls)
        assertEquals(90L, result.book.currentTime)
        assertEquals(ListeningPositionServerStatus.QUEUED, result.server)
        calls.clear()
        try { applier.apply(payload, book.copy(duration = 30)); fail("Out-of-range time must fail") } catch (_: IllegalArgumentException) { }
        assertTrue(calls.isEmpty())
    }

    @Test fun serializesRepeatedAcceptancesOfTheSameCopy() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val writes = mutableListOf<Long>()
        val target = object : ListeningPositionProgressTarget {
            override suspend fun <T> ordered(book: Book, action: suspend () -> T): T = action()
            override suspend fun reload(book: Book) = book
            override suspend fun saveReading(book: Book, location: SharedReadingLocation): Book = book.copy(
                epubProgress = location.progressionFor(book), readProgress = location.progressionFor(book), epubLocator = location.locatorFor(book))
            override suspend fun seekIfLoaded(book: Book, positionMilliseconds: Long) = Unit
            override suspend fun save(book: Book, positionMilliseconds: Long): Book {
                writes += positionMilliseconds
                return book.copy(currentTime = positionMilliseconds / 1000)
            }
            override suspend fun push(book: Book): ListeningPositionServerStatus {
                if (!entered.isCompleted) { entered.complete(Unit); release.await() }
                return ListeningPositionServerStatus.SAVED
            }
        }
        val applier = ListeningPositionApplier(target)
        val first = async { applier.apply(payload, book) }
        entered.await()
        val second = async { applier.apply(payload.copy(positionMilliseconds = 30000), book) }
        yield()
        assertEquals(listOf(90000L), writes)
        release.complete(Unit)
        first.await()
        second.await()
        assertEquals(listOf(90000L, 30000L), writes)
    }

    @Test fun readingCandidatesExcludeAudioAndKeepDifferentEditionsVisible() {
        val reading = payload.copy(positionMilliseconds = 0, durationMilliseconds = 0,
            readingLocation = SharedReadingLocation("comic", 250000, page = 5, pageCount = 20))
        val comic = book.copy(mediaType = AppMediaType.EBOOK, primaryFileType = "CBZ", pageCount = 20, duration = 0)
        val pdf = comic.copy(id = "pdf", primaryFileType = "PDF", pageCount = 40)
        val ranked = ListeningPositionMatcher.rank(listOf(book, comic, pdf), reading)
        assertEquals(2, ranked.size)
        assertTrue(ranked.all { it.hasCredibleIdentity })
        assertFalse(ranked.first { it.book.id == "pdf" }.warnings.isEmpty())
        assertFalse(ListeningPositionMatcher.evaluate(comic.copy(pageCount = 3), reading).canApply)
        assertFalse(ListeningPositionMatcher.evaluate(book, reading).canApply)
    }

    @Test fun readingApplyPreservesPageAndNeverSeeksAudio() = runBlocking {
        val reading = payload.copy(positionMilliseconds = 0, durationMilliseconds = 0,
            readingLocation = SharedReadingLocation("pdf", 250000, page = 5, pageCount = 20))
        val pdf = book.copy(mediaType = AppMediaType.EBOOK, primaryFileType = "PDF", pageCount = 40, epubProgress = 0.9f, isFinished = true)
        var seeks = 0
        var writes = 0
        val target = object : ListeningPositionProgressTarget {
            override suspend fun <T> ordered(book: Book, action: suspend () -> T): T = action()
            override suspend fun reload(book: Book) = book
            override suspend fun seekIfLoaded(book: Book, positionMilliseconds: Long) { seeks++ }
            override suspend fun save(book: Book, positionMilliseconds: Long) = error("Audio was not selected")
            override suspend fun saveReading(book: Book, location: SharedReadingLocation): Book {
                writes++
                val progress = location.progressionFor(book)
                return book.copy(epubProgress = progress, readProgress = progress, epubLocator = location.locatorFor(book), isFinished = progress >= 0.99f)
            }
            override suspend fun push(book: Book) = ListeningPositionServerStatus.QUEUED
        }
        val applier = ListeningPositionApplier(target)
        val result = applier.apply(reading, pdf)
        assertEquals(0, seeks)
        assertEquals(1, writes)
        assertEquals(0.125f, result.book.epubProgress!!, 0.00001f)
        assertEquals("""{"page":5,"enveSharedPosition":true}""", result.book.epubLocator)
        assertFalse(result.book.isFinished)
        assertEquals(ListeningPositionServerStatus.QUEUED, result.server)
        try { applier.apply(reading, pdf.copy(pageCount = 3)); fail("Out-of-range page must fail") } catch (_: IllegalArgumentException) { }
        try { applier.apply(reading, book); fail("Reading cannot overwrite audio") } catch (_: IllegalArgumentException) { }
        try { applier.apply(payload, pdf); fail("Audio cannot overwrite reading") } catch (_: IllegalArgumentException) { }
        assertEquals(1, writes)
    }

    @Test fun reflowablePositionAcceptedByAPdfKeepsAnAuthoritativeLocalPage() {
        val reading = SharedReadingLocation("epub", 250000, href = "OPS/chapter.xhtml", resourceProgressionUnits = 500000)
        val pdf = book.copy(mediaType = AppMediaType.EBOOK, primaryFileType = "PDF", pageCount = 100)
        assertEquals("""{"page":25,"enveSharedPosition":true}""", reading.locatorFor(pdf))
        assertEquals(0.25f, reading.progressionFor(pdf), 0.00001f)
    }

}
