package com.enve.silo

import com.enve.silo.dto.SiloCatalogItemDto
import com.enve.silo.dto.SiloCollection
import com.enve.silo.dto.SiloHistoryCardDto
import com.enve.silo.dto.SiloItemDetailDto
import com.enve.silo.dto.SiloLibraryDto
import com.enve.silo.dto.SiloLoginResponse
import com.enve.silo.dto.SiloProfileDto
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SiloServerToolsDtoTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; coerceInputValues = true }

    @Test
    fun decodesHistoryCardsWithWatchDurations() {
        val page = json.decodeFromString<SiloCollection<SiloHistoryCardDto>>(
            """
            {"items":[
              {"content_id":"c1","type":"ebook","title":"Piranesi","genres":[],"keywords":[],"status":"matched","watch":{"media_item_id":"c1","watched_at":"2026-01-02T03:04:05.000Z","duration_seconds":0,"completed":true}},
              {"content_id":"c2","type":"audiobook","title":"","series_title":"The Expanse","genres":[],"keywords":[],"status":"matched","runtime":61,"watch":{"media_item_id":"c2","watched_at":"2026-01-02T03:04:05.000Z","duration_seconds":3600.4,"completed":false}},
              {"content_id":"c3","type":"audiobook","title":"Minutes","genres":[],"keywords":[],"status":"matched","runtime":2,"watch":{"media_item_id":"c3","watched_at":"2026-01-02T03:04:05.000Z","duration_seconds":0,"completed":false}}
            ],"page":{"next_cursor":"abc","has_more":true}}
            """.trimIndent(),
        )

        assertEquals("abc", page.page?.nextCursor)
        val items = page.items.map { it.toHistoryItem() }
        assertEquals(0L, items[0].runtimeSeconds)
        assertEquals("Untitled", items[1].title)
        assertEquals("The Expanse", items[1].seriesTitle)
        assertEquals(3_600L, items[1].runtimeSeconds)
        assertEquals(120L, items[2].runtimeSeconds)
    }

    @Test
    fun similarCardsAreCatalogItems() {
        val response = json.decodeFromString<SiloCollection<SiloCatalogItemDto>>(
            """{"items":[{"content_id":"c9","type":"audiobook","title":"A","genres":[],"keywords":[],"status":"matched"}]}""",
        )

        assertEquals("c9", response.items.single().contentId)
        assertNull(response.page)
    }

    @Test
    fun identifiersAreOpaqueStrings() {
        val login = json.decodeFromString<SiloLoginResponse>(
            """{"access_token":"acc","refresh_token":"ref","expires_in":3600,"user":{"id":"1","username":"laura","email":"laura@example.test","role":"user","permissions":["marker_edit"],"download_allowed":true,"password_change_required":false}}""",
        )
        val libraries = json.decodeFromString<SiloCollection<SiloLibraryDto>>(
            """{"items":[{"id":"12","name":"Books","type":"audiobooks","sort_order":2,"box_sets_enabled":false}]}""",
        )
        val profiles = json.decodeFromString<SiloCollection<SiloProfileDto>>(
            """{"items":[{"id":"p-1","name":"Alice","has_pin":false,"is_child":false,"is_primary":true}]}""",
        )

        assertEquals("1", login.user.id)
        assertEquals("12", libraries.items.single().id)
        assertTrue(profiles.items.single().isPrimary)
    }

    @Test
    fun itemDetailReadsStringFileIdsAndRuntimeInMinutes() {
        val detail = json.decodeFromString<SiloItemDetailDto>(
            """
            {"content_id":"audiobook:x","type":"audiobook","title":"X","runtime":90,"genres":[],"keywords":[],"status":"matched",
             "user_data":{"position_seconds":30,"duration_seconds":5400,"watched_count":0,"unplayed_count":1,"in_progress_count":1,"played":false},
             "versions":[{"file_id":"120","file_name":"x.m4b","resolution":"","codec_video":"","codec_audio":"aac","hdr":false,"container":"m4b","file_size":10,"duration":5400,"bitrate":64,"added_at":"2026-01-02T03:04:05.000Z","chapters":[{"index":0,"title":"One","start_seconds":0,"end_seconds":60,"source":"embedded"}]}],
             "playback_variants":[{"variant_id":"v","part_count":2,"parts":[{"part_index":0,"default_file_id":"120","versions":[]},{"part_index":1,"versions":[]}]}],
             "audiobook":{"authors":[{"name":"A"}],"narrators":[],"total_duration_seconds":0,"other_narrations":[],"related":{"also_by_author":[],"similar":[]}},
             "cast":[],"crew":[],"ratings":[],"subtitles":[]}
            """.trimIndent(),
        )

        assertEquals(90, detail.runtimeMinutes)
        assertEquals("120", detail.versions.single().fileId)
        assertEquals("120", detail.playbackVariants!!.first().parts.first().defaultFileId)
        assertNull(detail.playbackVariants.first().parts[1].defaultFileId)
        assertEquals(0, detail.audiobook?.totalDurationSeconds)
    }

    @Test
    fun knownSortsMapToTheV2GrammarAndUnknownSortsUseTheServerDefault() {
        assertEquals("-added_at", siloSort("addedOn", "desc"))
        assertEquals("title", siloSort("title", "asc"))
        assertEquals("-progress", siloSort("progress", "DESC"))
        assertNull(siloSort("random_thing", "asc"))
    }
}
