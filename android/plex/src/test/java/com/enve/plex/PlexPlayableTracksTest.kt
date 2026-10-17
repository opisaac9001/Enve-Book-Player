package com.enve.plex

import com.enve.plex.api.PlexApi
import com.enve.plex.dto.PlexItemContainer
import com.enve.plex.dto.PlexItemResponse
import com.enve.plex.dto.PlexItemsContainer
import com.enve.plex.dto.PlexItemsResponse
import com.enve.plex.dto.PlexMedia
import com.enve.plex.dto.PlexMetadata
import com.enve.plex.dto.PlexPart
import com.enve.plex.dto.PlexSectionsResponse
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import retrofit2.Response

class PlexPlayableTracksTest {

    private class FakePlexApi(
        private val root: PlexMetadata,
        private val children: List<PlexMetadata> = emptyList(),
    ) : PlexApi {
        override suspend fun getSections(): Response<PlexSectionsResponse> = error("unused")
        override suspend fun getSectionItems(
            sectionId: String, type: Int?, includeMedia: Int, sort: String?, start: Int, size: Int,
        ): Response<PlexItemsResponse> = error("unused")
        override suspend fun getMetadata(ratingKey: String, includeChapters: Int): Response<PlexItemResponse> =
            Response.success(PlexItemResponse(PlexItemContainer(listOf(root))))
        override suspend fun getMetadataChildren(ratingKey: String, includeMedia: Int): Response<PlexItemsResponse> =
            Response.success(PlexItemsResponse(PlexItemsContainer(children)))
        override suspend fun getOnDeck(size: Int): Response<PlexItemsResponse> = error("unused")
        override suspend fun reportProgress(
            ratingKey: String, identifier: String, timeMs: Long, state: String,
        ): Response<Unit> = error("unused")
        override suspend fun reportTimeline(
            ratingKey: String, key: String, state: String, timeMs: Long, durationMs: Long, sessionId: String, identifier: String,
        ): Response<Unit> = error("unused")
        override suspend fun scrobble(ratingKey: String, identifier: String): Response<Unit> = error("unused")
        override suspend fun unscrobble(ratingKey: String, identifier: String): Response<Unit> = error("unused")
    }

    private val album = PlexMetadata(ratingKey = "album-1", type = "album", title = "Album")

    private fun media(container: String?, key: String?, durationMs: Long) = PlexMedia(
        duration = durationMs,
        container = container,
        part = listOfNotNull(key?.let { PlexPart(id = 1, key = it) }),
    )

    private fun track(id: String, disc: Int, index: Int, vararg media: PlexMedia) = PlexMetadata(
        ratingKey = id, type = "track", title = "Track $id", parentIndex = disc, index = index,
        duration = 99_000, media = media.toList(),
    )

    @Test
    fun albumTracksUseOneSupportedRenditionInDiscAndTrackOrder() = runBlocking {
        val api = FakePlexApi(album, listOf(
            track("21", 2, 1, media("asf", "/library/parts/21/a.wma", 50_000), media("mp3", "/library/parts/21/b.mp3", 40_000)),
            track("12", 1, 2, media("mp3", "/library/parts/12/c.mp3", 30_000)),
            track("11", 1, 1, media("m4b", "/library/parts/11/d.m4b", 20_000)),
        ))

        val playable = api.playableTracks("album-1")!!

        assertTrue(playable.isAlbum)
        assertEquals(listOf("11", "12", "21"), playable.tracks.map { it.metadata.ratingKey })
        assertEquals(listOf(0L, 20_000L, 50_000L), playable.tracks.map { it.startMs })
        assertEquals(listOf(20_000L, 30_000L, 40_000L), playable.tracks.map { it.durationMs })
        assertEquals(
            listOf("/library/parts/11/d.m4b", "/library/parts/12/c.mp3", "/library/parts/21/b.mp3"),
            playable.tracks.map { it.rendition.part.key },
        )
    }

    @Test
    fun trackWithoutAnyPartFailsTheWholeBook() = runBlocking {
        val api = FakePlexApi(album, listOf(
            track("11", 1, 1, media("mp3", "/library/parts/11/a.mp3", 20_000)),
            track("12", 1, 2, media("mp3", null, 30_000)),
        ))

        try {
            api.playableTracks("album-1")
            fail("Expected a missing part to fail")
        } catch (expected: IllegalStateException) {
        }
    }

    @Test
    fun singleTrackFallsBackToFirstPartWhenNoRenditionIsSupported() = runBlocking {
        val single = track("7", 1, 1, media("asf", "/library/parts/7/a.wma", 10_000), media("ape", "/library/parts/7/b.ape", 12_000))

        val playable = FakePlexApi(single).playableTracks("7")!!

        assertFalse(playable.isAlbum)
        assertEquals(listOf("/library/parts/7/a.wma"), playable.tracks.map { it.rendition.part.key })
        assertEquals(listOf(10_000L), playable.tracks.map { it.durationMs })
    }

    @Test
    fun containerlessRenditionIsJudgedByCodecThenFileExtension() {
        val codecOnly = PlexMedia(audioCodec = "opus", part = listOf(PlexPart(id = 1, key = "/a")))
        val fileOnly = PlexMedia(part = listOf(PlexPart(id = 2, key = "/b", file = "/books/b.flac")))
        val item = PlexMetadata(ratingKey = "1", type = "track", title = "T",
            media = listOf(PlexMedia(container = "asf", part = listOf(PlexPart(id = 3, key = "/c"))), fileOnly, codecOnly))

        assertEquals("/b", item.playableRendition()?.part?.key)
        assertEquals("opus", PlexMetadata(ratingKey = "2", type = "track", title = "T", media = listOf(codecOnly))
            .playableRendition()?.format)
    }
}
