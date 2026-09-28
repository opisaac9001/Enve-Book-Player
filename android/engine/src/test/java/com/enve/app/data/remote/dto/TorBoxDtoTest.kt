package com.enve.app.data.remote.dto

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TorBoxDtoTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; coerceInputValues = true }

    @Test
    fun torrentListDecodesTheSdkDocumentedShape() {
        val response = json.decodeFromString<TorBoxListResponseDto>(
            """{"success":true,"error":null,"detail":"Torrent list retrieved successfully.","data":[{"active":false,"auth_id":"auth","availability":1.0,"created_at":"2024-01-01T00:00:00Z","download_finished":true,"download_present":true,"download_speed":0,"download_state":"cached","eta":0,"expires_at":"2024-02-01T00:00:00Z","files":[{"id":0,"md5":"d41d8cd98f00b204e9800998ecf8427e","mimetype":"audio/mp4","name":"Narrated Regression/Narrated Regression.m4b","s3_path":"hash/Narrated Regression/Narrated Regression.m4b","short_name":"Narrated Regression.m4b","size":10485760}],"hash":"0123456789abcdef","id":4821,"inactive_check":0,"magnet":"magnet:?xt=urn:btih:0123456789abcdef","name":"Narrated Regression","peers":0,"progress":1,"ratio":0,"seeds":0,"server":1,"size":10485760,"torrent_file":false,"updated_at":"2024-01-01T00:00:00Z","upload_speed":0}]}"""
        )

        val torrent = response.data!!.single()
        assertEquals(4821L, torrent.id)
        assertEquals("Narrated Regression", torrent.name)
        assertEquals(true, torrent.downloadPresent)
        assertEquals(true, torrent.downloadFinished)
        val file = torrent.files.single()
        assertEquals(0L, file.id)
        assertEquals("Narrated Regression/Narrated Regression.m4b", file.name)
        assertEquals("Narrated Regression.m4b", file.shortName)
        assertEquals(10_485_760L, file.size)
        assertEquals("hash/Narrated Regression/Narrated Regression.m4b", file.s3Path)
    }

    @Test
    fun usenetAndWebDownloadListsShareTheShape() {
        val usenet = json.decodeFromString<TorBoxListResponseDto>(
            """{"success":true,"error":null,"detail":"Usenet downloads list retrieved successfully.","data":[{"id":69,"created_at":"2025-07-30T20:40:42Z","updated_at":"2025-07-30T20:44:35Z","auth_id":"auth","name":"Usenet Book","hash":"abc","download_state":"completed","download_speed":0,"eta":0,"progress":1,"size":69,"files":[{"id":1,"md5":null,"name":"Usenet Book/01.mp3","size":6442450944,"s3_path":"abc/Usenet Book/01.mp3","mimetype":"audio/mpeg","short_name":"01.mp3"}]}]}"""
        )
        val webdl = json.decodeFromString<TorBoxListResponseDto>(
            """{"success":true,"error":null,"detail":"Web Download list retrieved successfully.","data":[{"id":7,"hash":"def","created_at":"2023-12-22T22:12:34.78989+00:00","updated_at":"2023-12-22T16:12:41.552423+00:00","size":0,"active":true,"auth_id":"auth","download_state":"downloading","progress":1,"download_speed":0,"upload_speed":0,"name":"WebDownloadName","eta":8640000,"server":0,"torrent_file":false,"expires_at":"2024-01-05T22:13:10.135864+00:00","download_present":false,"download_finished":false,"error":"Some error.","files":[],"inactive_check":0,"availability":0}]}"""
        )

        val usenetItem = usenet.data!!.single()
        assertNull(usenetItem.downloadPresent)
        assertEquals(6_442_450_944L, usenetItem.files.single().size)
        val webItem = webdl.data!!.single()
        assertEquals(7L, webItem.id)
        assertEquals(false, webItem.downloadPresent)
        assertTrue(webItem.files.isEmpty())
    }

    @Test
    fun emptyListResponseHasNoData() {
        val response = json.decodeFromString<TorBoxListResponseDto>(
            """{"success":true,"error":"ITEM_NOT_FOUND","detail":"No Usenet downloads found for this user.","data":null}"""
        )

        assertNull(response.data)
    }
}
