package com.enve.audiobookshelf

import org.junit.Assert.assertEquals
import org.junit.Test

class AbsCollectionLibraryIdTest {
    private val libraryId = "71b172fc-7dc2-4d3f-9580-af6ea375fd64"

    @Test
    fun preservesServerLibraryId() {
        assertEquals(libraryId, absRemoteLibraryId(libraryId))
    }

    @Test
    fun removesConnectionAndAccountScope() {
        assertEquals(libraryId, absRemoteLibraryId("audiobookshelf|https://example.invalid|reader::$libraryId"))
    }

    @Test
    fun acceptsLegacySourceScope() {
        assertEquals(libraryId, absRemoteLibraryId("AUDIOBOOKSHELF::$libraryId"))
    }

    @Test
    fun keepsIpv6AndAccountSeparatorsOutOfTheRemoteId() {
        assertEquals(libraryId, absRemoteLibraryId("audiobookshelf|http://[::1]:13378|reader::account::$libraryId"))
    }
}
