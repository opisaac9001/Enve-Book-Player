package com.enve.app.data.kavita

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KavitaCoverRevisionStoreTest {
    @Test fun repeatedReadsKeepArtworkCachedUntilExplicitRefresh() {
        val store = KavitaCoverRevisionStore()
        val first = store.revision
        assertEquals(first, store.revision)
        store.invalidate()
        val refreshed = store.revision
        assertTrue(refreshed > first)
        assertEquals(refreshed, store.revision)
        store.invalidate()
        assertTrue(store.revision > refreshed)
    }
}
