package com.enve.app.data.repository

import org.junit.Assert.assertEquals
import org.junit.Test

class TorBoxFileMergeTest {
    private val api = CloudAudioFile("api", "Chapter & Credits.mp3", "Book/Chapter & Credits.mp3", "Book", "https://fixture/requestdl", 100)

    @Test
    fun webDavAddsMetadataWithoutChangingApiIdentityOrPlaybackUrl() {
        val webDav = api.copy(id = "webdav", link = "https://fixture/webdav", size = 200, coverUrl = "cover")
        assertEquals(listOf(api.copy(coverUrl = "cover")), mergeTorBoxFiles(listOf(api), listOf(webDav)))
    }

    @Test
    fun omittedAmpersandMatchesUniqueApiTrack() {
        val webDav = api.copy(id = "webdav", path = "Book/Chapter  Credits.mp3", name = "Chapter  Credits.mp3", coverUrl = "cover")
        assertEquals(listOf(api.copy(coverUrl = "cover")), mergeTorBoxFiles(listOf(api), listOf(webDav)))
    }

    @Test
    fun exactPathWinsWhenSanitizedNamesCollide() {
        val other = api.copy(id = "other", path = "Book/Chapter  Credits.mp3", name = "Chapter  Credits.mp3")
        val webDav = other.copy(id = "webdav", coverUrl = "cover")
        assertEquals(listOf(api, other.copy(coverUrl = "cover")), mergeTorBoxFiles(listOf(api, other), listOf(webDav)))
    }

    @Test
    fun ambiguousAliasesDoNotOverwriteDistinctApiFiles() {
        val first = api.copy(path = "Book/A&B.mp3")
        val second = api.copy(id = "second", path = "Book/AB&.mp3")
        val webDav = api.copy(id = "webdav", path = "Book/AB.mp3")
        assertEquals(listOf(first, second, webDav), mergeTorBoxFiles(listOf(first, second), listOf(webDav)))
    }

    @Test
    fun webDavOnlyBooksAreRetained() {
        val webDav = api.copy(id = "webdav", path = "Other/Track.mp3", parentFolder = "Other")
        assertEquals(listOf(api, webDav), mergeTorBoxFiles(listOf(api), listOf(webDav)))
    }
    @Test
    fun apiCoverIsNotReplacedByCredentialBearingWebDavCover() {
        val covered = api.copy(coverUrl = "api-cover")
        val webDav = api.copy(coverUrl = "webdav-cover")
        assertEquals(listOf(covered), mergeTorBoxFiles(listOf(covered), listOf(webDav)))
    }

}
