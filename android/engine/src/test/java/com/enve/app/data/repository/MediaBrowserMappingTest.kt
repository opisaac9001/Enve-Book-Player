package com.enve.app.data.repository

import com.enve.app.data.remote.dto.JellyfinUserDto
import com.enve.app.data.remote.dto.MediaBrowserItemsDto
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class MediaBrowserMappingTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun jellyfinViewsKeepOnlyBookCollections() {
        val views = json.decodeFromString<MediaBrowserItemsDto>(
            """{"Items":[{"Name":"EnveAudiobooks","ServerId":"fixture-id-1","Id":"fixture-id-2","ChildCount":4,"IsFolder":true,"Type":"CollectionFolder","CollectionType":"books","ImageTags":{}},{"Name":"EnveMovies","ServerId":"fixture-id-1","Id":"fixture-id-3","ChildCount":5,"IsFolder":true,"Type":"CollectionFolder","CollectionType":"movies","ImageTags":{"Primary":"fixture-id-4"}}],"TotalRecordCount":2,"StartIndex":0}"""
        )

        val libraries = views.items.mapNotNull { it.toBookLibraryOrNull() }

        assertEquals(1, libraries.size)
        assertEquals("fixture-id-2", libraries[0].id)
        assertEquals("EnveAudiobooks", libraries[0].name)
        assertEquals(4, libraries[0].bookCount)
    }

    @Test
    fun jellyfinPlayedPercentageIsAPercent() {
        val items = json.decodeFromString<MediaBrowserItemsDto>(
            """{"Items":[{"Name":"Disc 1 Chapter 1","ServerId":"fixture-id-1","Id":"fixture-id-5","RunTimeTicks":40489800,"IndexNumber":1,"ParentIndexNumber":1,"IsFolder":false,"Type":"AudioBook","UserData":{"PlayedPercentage":24.69757815548607,"PlaybackPositionTicks":10000000,"PlayCount":0,"IsFavorite":false,"Played":false,"Key":"fixture-id-6","ItemId":"fixture-id-5"},"ImageTags":{},"BackdropImageTags":[],"LocationType":"FileSystem","MediaType":"Audio"},{"Name":"1","ServerId":"fixture-id-1","Id":"fixture-id-7","ChannelId":null,"RunTimeTicks":10000000,"Type":"Book","UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"ImageTags":{},"MediaType":"Book"}],"TotalRecordCount":2,"StartIndex":0}"""
        )

        val audiobook = items.items[0].toJellyfinBook("http://jellyfin.test/", "lib")!!
        assertEquals(0.2469f, audiobook.readProgress, 0.0001f)
        assertEquals(4L, audiobook.duration)
        assertEquals(1L, audiobook.currentTime)
        assertEquals(AppMediaType.AUDIOBOOK, audiobook.mediaType)
        assertEquals(BookSource.JELLYFIN, audiobook.source)
        assertEquals("http://jellyfin.test/Items/fixture-id-5/Images/Primary", audiobook.coverUrl)
        assertFalse(audiobook.isFinished)

        val ebook = items.items[1].toJellyfinBook("http://jellyfin.test", "lib")!!
        assertEquals(AppMediaType.EBOOK, ebook.mediaType)
        assertEquals(0f, ebook.readProgress)
    }

    @Test
    fun embyUsersListResolvesTheUserId() {
        val users = json.decodeFromString<List<JellyfinUserDto>>(
            """[{"Name":"reader","ServerId":"fixture-id-8","Prefix":"R","DateCreated":"2026-08-01T00:00:00.0000000Z","Id":"fixture-id-9","HasPassword":true,"HasConfiguredPassword":true}]"""
        )
        assertEquals("fixture-id-9", users.single { it.Name == "reader" }.Id)
    }

    @Test
    fun embyBooksAndAudioChildrenDecode() {
        val books = json.decodeFromString<MediaBrowserItemsDto>(
            """{"Items":[{"Name":"Fixture Ebook","ServerId":"fixture-id-8","Id":"141","IsFolder":false,"ParentId":"18","Type":"Book","UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"ImageTags":{},"BackdropImageTags":[],"MediaType":"Book"}],"TotalRecordCount":1}"""
        )
        val book = books.items.single().toEmbyBook("http://emby.test", "18")!!
        assertEquals(AppMediaType.EBOOK, book.mediaType)
        assertEquals(BookSource.EMBY, book.source)
        assertNull(book.coverUrl)

        val children = json.decodeFromString<MediaBrowserItemsDto>(
            """{"Items":[{"Name":"01 - MP3 VBR","ServerId":"fixture-id-8","Id":"12","RunTimeTicks":200400000,"IndexNumber":1,"IsFolder":false,"ParentId":"8","Type":"Audio","UserData":{"PlayedPercentage":4.990019960079841,"PlaybackPositionTicks":10000000,"PlayCount":0,"IsFavorite":false,"Played":false},"Artists":["Enve Test Artist"],"Album":"Codec Matrix","AlbumId":"24","AlbumArtist":"Enve Test Artist","ImageTags":{},"BackdropImageTags":[],"MediaType":"Audio"}],"TotalRecordCount":1}"""
        )
        val track = children.items.single()
        assertEquals("Audio", track.type)
        assertEquals(20_040L, track.durationMs)
        assertEquals(4.99, track.userData!!.playedPercentage!!, 0.01)
    }

    @Test
    fun jellyfinNarratorComesFromComposerPeople() {
        val items = json.decodeFromString<MediaBrowserItemsDto>(
            """{"Items":[{"Name":"Narrated Regression","ServerId":"fixture-id-1","Id":"fixture-id-10","HasLyrics":false,"PremiereDate":"0001-01-01T00:00:00.0000000Z","ChannelId":null,"RunTimeTicks":600000000,"IsFolder":false,"Type":"AudioBook","People":[{"Name":"Nora Narrator","Id":"fixture-id-11","Role":"","Type":"Composer"}],"UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false,"Key":"Enve Test Author-Narrated Regression-Narrated Regression","ItemId":"fixture-id-10"},"Artists":["Enve Test Author"],"ArtistItems":[{"Name":"Enve Test Author","Id":"fixture-id-12"}],"Album":"Narrated Regression","AlbumArtist":"Enve Test Author","AlbumArtists":[{"Name":"Enve Test Author","Id":"fixture-id-12"}],"ImageTags":{},"BackdropImageTags":[],"ImageBlurHashes":{},"LocationType":"FileSystem","MediaType":"Audio"}],"TotalRecordCount":1,"StartIndex":0}"""
        )

        val book = items.items.single().toJellyfinBook("http://jellyfin.test", "fixture-id-2")!!

        assertEquals("Nora Narrator", book.narrator)
        assertEquals("Enve Test Author", book.author)
        assertEquals(AppMediaType.AUDIOBOOK, book.mediaType)
    }

    @Test
    fun embyNarratorComesFromComposers() {
        val albums = json.decodeFromString<MediaBrowserItemsDto>(
            """{"Items":[{"Name":"Narrated Regression","ServerId":"fixture-id-8","Id":"149","RunTimeTicks":600000000,"IsFolder":true,"Type":"MusicAlbum","UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"Artists":["Enve Test Author"],"ArtistItems":[{"Name":"Enve Test Author","Id":"148"}],"Composers":[{"Name":"Nora Narrator","Id":"151"}],"AlbumArtist":"Enve Test Author","AlbumArtists":[{"Name":"Enve Test Author","Id":"148"}],"ImageTags":{},"BackdropImageTags":[]}],"TotalRecordCount":1}"""
        )
        val tracks = json.decodeFromString<MediaBrowserItemsDto>(
            """{"Items":[{"Name":"Narrated Regression","ServerId":"fixture-id-8","Id":"147","RunTimeTicks":600000000,"IsFolder":false,"ParentId":"146","Type":"Audio","UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"Artists":["Enve Test Author"],"ArtistItems":[{"Name":"Enve Test Author","Id":"148"}],"Composers":[{"Name":"Nora Narrator","Id":"151"}],"Album":"Narrated Regression","AlbumId":"149","AlbumArtist":"Enve Test Author","AlbumArtists":[{"Name":"Enve Test Author","Id":"148"}],"ImageTags":{},"BackdropImageTags":[],"MediaType":"Audio"}],"TotalRecordCount":1}"""
        )

        assertEquals("Nora Narrator", albums.items.single().toEmbyBook("http://emby.test", "3")!!.narrator)
        assertEquals("Nora Narrator", tracks.items.single().toEmbyBook("http://emby.test", "3")!!.narrator)
        assertEquals("Enve Test Author", albums.items.single().toEmbyBook("http://emby.test", "3")!!.author)
    }
}
