package com.enve.audiobookshelf

import com.enve.audiobookshelf.dto.AbsLibraryItemDto
import com.enve.audiobookshelf.dto.AbsMeResponse
import com.enve.audiobookshelf.dto.AbsMediaProgressDto
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.PodcastFeedKey
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AbsPodcastMappingTest {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }
    private val serverUrl = "http://abs.test/"

    private fun item(name: String): AbsLibraryItemDto = json.decodeFromString(fixture(name))

    private fun progress(): List<AbsMediaProgressDto> =
        json.decodeFromString<AbsMeResponse>(fixture("me_progress.json")).mediaProgress

    private fun fixture(name: String): String =
        checkNotNull(javaClass.classLoader?.getResource("abs/$name")) { "Missing fixture $name" }.readText()

    @Test
    fun mapsExpandedShowAndEpisodeFields() {
        val show = mapAbsPodcastShow(item("podcast_item_expanded.json"), progress(), serverUrl)

        assertEquals("69705e22-3e69-43f3-ba42-64178e997530", show.id)
        assertEquals("Accidental Tech Podcast", show.title)
        assertEquals("Marco Arment, Casey Liss, John Siracusa", show.author)
        assertEquals(listOf("Technology"), show.genres)
        assertEquals("http://abs.test/api/items/69705e22-3e69-43f3-ba42-64178e997530/cover", show.coverUrl)

        val episode = show.episodes.single()
        assertEquals("69705e22-3e69-43f3-ba42-64178e997530_7ac76a99-00a6-4801-9659-82a6d809db7f", episode.id)
        assertEquals("7ac76a99-00a6-4801-9659-82a6d809db7f", episode.episodeId)
        assertEquals(show.id, episode.podcastLibraryItemId)
        assertEquals("709: Steel-Cable Insurance", episode.title)
        assertEquals("Accidental Tech Podcast", episode.podcastName)
        assertEquals(AppMediaType.PODCAST, episode.mediaType)
        assertEquals(BookSource.AUDIOBOOKSHELF, episode.source)
        assertEquals(7662L, episode.duration)
        assertEquals(1789680369000L, episode.addedOn)
        assertEquals("c37bb17d-2d06-4e6d-b763-66c6c0ff9c25", episode.libraryId)
        assertEquals(show.coverUrl, episode.coverUrl)
        assertTrue(episode.description.orEmpty().startsWith("<ul>"))
        assertEquals(0L, episode.currentTime)
        assertFalse(episode.isFinished)
        assertEquals("https://cdn.atp.fm/rss/public?wtvryzdm", show.feedUrl)
        assertEquals(
            listOf(
                PodcastFeedKey(
                    guid = "svdeou1mmfjhwknm",
                    enclosureUrl = "https://atp.fm/audio/svdeou1mmfjhwknm/atp709.mp3",
                    title = "709: Steel-Cable Insurance",
                    publishedAtMs = 1789680369000L,
                ),
            ),
            show.storedFeedKeys,
        )
    }

    @Test
    fun fallsBackToAudioFileDurationAndAddedAtOnMinimalItems() {
        val show = mapAbsPodcastShow(item("podcast_item_minimal.json"), progress(), serverUrl)

        assertEquals(listOf(30L, 31L), show.episodes.map { it.duration })
        assertEquals(listOf(1786508087473L, 1788223215769L), show.episodes.map { it.addedOn })
        assertEquals("Episode 2 - Unicode 日本語 العربية", show.episodes[1].title)
        assertEquals(null, show.description)
        assertEquals(null, show.feedUrl)
        assertEquals(listOf(null, null), show.storedFeedKeys.map { it.guid })
    }

    @Test
    fun appliesOnlyThisShowsEpisodeProgress() {
        val item = item("podcast_item_minimal.json")
        val (first, second) = checkNotNull(item.media?.episodes).map { it.id }
        val entries = listOf(
            AbsMediaProgressDto(libraryItemId = item.id, episodeId = first, currentTime = 12.0, duration = 30.0065, progress = 0.4f, lastUpdate = 99L),
            AbsMediaProgressDto(libraryItemId = item.id, episodeId = second, currentTime = 31.0, duration = 31.0, progress = 1f, isFinished = true),
            AbsMediaProgressDto(libraryItemId = "another-show", episodeId = first, currentTime = 25.0, progress = 0.8f),
            AbsMediaProgressDto(libraryItemId = item.id, currentTime = 5.0, progress = 0.1f),
        )

        val episodes = mapAbsPodcastShow(item, entries, serverUrl).episodes

        assertEquals(12L, episodes[0].currentTime)
        assertEquals(0.4f, episodes[0].readProgress)
        assertEquals(99L, episodes[0].lastReadTime)
        assertFalse(episodes[0].isFinished)
        assertTrue(episodes[1].isFinished)
    }
}
