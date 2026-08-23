package com.enve.app.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EbookReaderResumeSelectionTest {

    @Test
    fun downloadedBookSkipsReaderNetworkWhenInternetIsAvailable() {
        assertEquals(
            false,
            shouldUseReaderNetwork(
                hasOfflineSource = true,
                networkAvailable = true,
            ),
        )
    }

    @Test
    fun nonDownloadedBookUsesAvailableReaderNetwork() {
        assertEquals(
            true,
            shouldUseReaderNetwork(
                hasOfflineSource = false,
                networkAvailable = true,
            ),
        )
    }

    @Test
    fun remoteProgressDoesNotReuseStaleCachedAudioSeconds() {
        assertNull(
            selectAudioResumeSeconds(
                locatorAudioSeconds = null,
                cachedAudioSeconds = 12_345L,
                mayUseCachedAudioPosition = false,
            ),
        )
    }

    @Test
    fun localProgressUsesExactCachedAudioSeconds() {
        assertEquals(
            12_345L,
            selectAudioResumeSeconds(
                locatorAudioSeconds = null,
                cachedAudioSeconds = 12_345L,
                mayUseCachedAudioPosition = true,
            ),
        )
    }

    @Test
    fun locatorAudioSecondsRemainAuthoritative() {
        assertEquals(
            99L,
            selectAudioResumeSeconds(
                locatorAudioSeconds = 99L,
                cachedAudioSeconds = 12_345L,
                mayUseCachedAudioPosition = false,
            ),
        )
    }
}
