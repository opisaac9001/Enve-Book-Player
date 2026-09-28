package com.enve.audiobookshelf

import com.enve.audiobookshelf.dto.AbsMediaProgressDto
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import org.junit.Assert.assertEquals
import org.junit.Test

class AbsProgressNormalizationTest {
    @Test
    fun resettingPreviouslyUnifiedAudioProgressClearsFinishedState() {
        val book = Book(id = "audio", title = "Audio", duration = 1000L,
            currentTime = 1000L, isFinished = true, readProgress = 1f, epubProgress = 1f)
        val updated = applyAbsMediaProgress(book, AbsMediaProgressDto(
            currentTime = 0.0, progress = 0f, isFinished = false, lastUpdate = 1_800_000_000_000L,
        ))
        assertEquals(0L, updated.currentTime)
        assertEquals(false, updated.isFinished)
        assertEquals(null, updated.epubProgress)
    }

    @Test
    fun ebookResetClearsOldLocator() {
        val book = Book(id = "ebook", title = "Ebook", mediaType = AppMediaType.EBOOK,
            epubProgress = 0.5f, epubLocator = "old-locator")
        val updated = applyAbsMediaProgress(book, AbsMediaProgressDto(ebookProgress = 0f))
        assertEquals(0f, updated.epubProgress)
        assertEquals(null, updated.epubLocator)
    }

    @Test
    fun anAudioOnlyRecordNeverRewindsADualItemsEbook() {
        val locator = """{"href":"text/ch2.xhtml","locations":{"progression":0,"totalProgression":0.13}}"""
        val book = Book(id = "dual", title = "Dual", duration = 2400L, currentTime = 100L, readProgress = 0.04f,
            epubProgress = 1f, epubLocator = locator, hasAudio = true, hasEbook = true, lastReadTime = 1_000L)
        val updated = applyAbsMediaProgress(book, AbsMediaProgressDto(
            currentTime = 600.0, duration = 2400.0, progress = 0.25f, ebookProgress = 0f, lastUpdate = 5_000L,
        ))
        assertEquals(1f, updated.epubProgress)
        assertEquals(locator, updated.epubLocator)
        assertEquals(600L, updated.currentTime)
        assertEquals(5_000L, updated.lastReadTime)
    }

    @Test
    fun anEbookOnlyRecordNeverRewindsADualItemsAudio() {
        val book = Book(id = "dual", title = "Dual", duration = 2400L, currentTime = 600L, readProgress = 0.25f,
            epubProgress = 0.1f, hasAudio = true, hasEbook = true, lastReadTime = 1_000L)
        val updated = applyAbsMediaProgress(book, AbsMediaProgressDto(
            currentTime = 0.0, duration = 0.0, progress = 0f, ebookProgress = 0.4f,
            ebookLocation = "epubcfi(/6/20!/4/2)", lastUpdate = 5_000L,
        ))
        assertEquals(600L, updated.currentTime)
        assertEquals(0.25f, updated.readProgress)
        assertEquals(0.4f, updated.epubProgress)
    }

    @Test
    fun onlyALocationOrAPositiveFractionIsAnEbookPosition() {
        assertEquals(false, absHasEbookPosition(AbsMediaProgressDto(ebookProgress = 0f, currentTime = 600.0)))
        assertEquals(false, absHasEbookPosition(AbsMediaProgressDto(ebookLocation = " ")))
        assertEquals(true, absHasEbookPosition(AbsMediaProgressDto(ebookProgress = 0f, ebookLocation = "epubcfi(/6/2!/4/2)")))
        assertEquals(true, absHasEbookPosition(AbsMediaProgressDto(ebookProgress = 0.2f)))
    }

    @Test
    fun audioPushLeavesTheSharedFinishedFlagAloneUntilItFinishes() {
        val json = kotlinx.serialization.json.Json { encodeDefaults = true }
        val listening = json.encodeToString(
            com.enve.audiobookshelf.dto.AbsProgressUpdateRequest.serializer(),
            com.enve.audiobookshelf.dto.AbsProgressUpdateRequest(currentTime = 600.0, duration = 2400.0, progress = 0.25f),
        )
        val finishing = json.encodeToString(
            com.enve.audiobookshelf.dto.AbsProgressUpdateRequest.serializer(),
            com.enve.audiobookshelf.dto.AbsProgressUpdateRequest(currentTime = 2400.0, duration = 2400.0, progress = 1f, isFinished = true),
        )
        assertEquals(false, "isFinished" in listening)
        assertEquals(false, "ebook" in listening)
        assertEquals(true, "\"isFinished\":true" in finishing)
    }

    @Test
    fun explicitResetDoesNotRestoreCachedPosition() {
        assertEquals(0L, normalizeAbsCurrentTimeSeconds(0.0, 1000L, 0f, 900L))
        assertEquals(0L, normalizeAbsCurrentTimeSeconds(null, 1000L, 0f, 900L))
        assertEquals(0L, normalizeAbsCurrentTimeSeconds(0.0, 0L, null, 900L))
    }

    @Test
    fun missingProgressPreservesCachedPosition() {
        assertEquals(900L, normalizeAbsCurrentTimeSeconds(null, 1000L, null, 900L))
    }

    @Test
    fun serverSecondsAreClampedToDuration() {
        assertEquals(120L, normalizeAbsCurrentTimeSeconds(120.0, 1000L, 0.12f, 0L))
        assertEquals(500L, normalizeAbsCurrentTimeSeconds(0.0, 1000L, 0.5f, 900L))
        assertEquals(1000L, normalizeAbsCurrentTimeSeconds(1100.0, 1000L, null, null))
    }

    @Test
    fun serverCfiNeverReplacesTheLocalReaderLocator() {
        val local = """{"href":"text/ch1.xhtml","locations":{"fragments":["ch1-sentence59"]}}"""
        val book = Book(id = "ebook", title = "Ebook", mediaType = AppMediaType.EBOOK, epubProgress = 0.3f, epubLocator = local)

        val unchanged = applyAbsMediaProgress(book, AbsMediaProgressDto(ebookProgress = 0.3f, ebookLocation = "epubcfi(/6/12!/4/2/1:0)"))
        val moved = applyAbsMediaProgress(book, AbsMediaProgressDto(ebookProgress = 0.4f, ebookLocation = "epubcfi(/6/12!/4/2/1:0)"))
        val legacy = applyAbsMediaProgress(book, AbsMediaProgressDto(ebookProgress = 0.4f, ebookLocation = local))

        assertEquals(local, unchanged.epubLocator)
        assertEquals(null, moved.epubLocator)
        assertEquals(local, legacy.epubLocator)
    }

    @Test
    fun checkpointLocationIsReadAsItsReadiumLocator() {
        val locator = """{"href":"text/ch1.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.08}}"""
        val checkpoint = com.enve.core.reader.EpubBridgeCheckpointCodec.fromReadiumLocator(
            locatorJson = locator, publicationSha256 = "abc", providerFileId = null,
            writerEpoch = 1, revision = 1, observedAt = 1,
        )!!
        assertEquals(locator, absReadiumLocator(com.enve.core.reader.EpubBridgeCheckpointCodec.encode(checkpoint)))
        assertEquals(locator, absReadiumLocator(locator))
    }

    @Test
    fun serverMediaProgressDecodesAsSecondsAndEpochMillis() {
        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        val progress = json.decodeFromString<AbsMediaProgressDto>(
            """{"id":"04db5361-3ad6-494b-8fd7-23dbcf6be895","libraryItemId":"c844852c-5cd7-4aaf-bc9c-e1ae04f6fdfb","episodeId":null,"mediaItemId":"84c42e6e-840e-4e12-a6de-f01eafc78638","mediaItemType":"book","duration":17921.830385999998,"progress":0.007641669020926757,"currentTime":136.000088684,"isFinished":false,"hideFromContinueListening":false,"ebookLocation":null,"ebookProgress":0,"lastUpdate":1788147921437,"startedAt":1788147785437,"finishedAt":null}"""
        )
        val book = applyAbsMediaProgress(Book(id = "audio", title = "Audio"), progress)
        assertEquals(17921L, book.duration)
        assertEquals(136L, book.currentTime)
        assertEquals(1_788_147_921_437L, book.lastReadTime)
        assertEquals(false, book.isFinished)
    }
}
