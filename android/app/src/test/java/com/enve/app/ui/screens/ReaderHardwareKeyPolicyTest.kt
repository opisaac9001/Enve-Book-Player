package com.enve.app.ui.screens

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ReaderHardwareKeyPolicyTest {
    @Test
    fun pageTurnOnlyFiresForInitialKeyDown() {
        assertEquals(true, ReaderHardwareKeyPolicy.shouldTriggerTurn(KeyEvent.ACTION_DOWN, 0))
        assertEquals(false, ReaderHardwareKeyPolicy.shouldTriggerTurn(KeyEvent.ACTION_DOWN, 1))
        assertEquals(false, ReaderHardwareKeyPolicy.shouldTriggerTurn(KeyEvent.ACTION_UP, 0))
    }

    @Test
    fun standardDevicesOnlyUseVolumeKeysWhenEnabledAndAudioIsIdle() {
        assertEquals(
            ReaderPageKeyDirection.FORWARD,
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_VOLUME_UP,
                einkActive = false,
                volumeButtonNavigation = true,
                audioActive = false,
            ),
        )

        assertNull(
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_VOLUME_UP,
                einkActive = false,
                volumeButtonNavigation = true,
                audioActive = true,
            ),
        )

        assertNull(
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_PAGE_DOWN,
                einkActive = false,
                volumeButtonNavigation = true,
                audioActive = false,
            ),
        )
    }

    @Test
    fun einkDevicesUsePhysicalPageKeysInColorAndMonochromeModes() {
        assertEquals(
            ReaderPageKeyDirection.FORWARD,
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_PAGE_DOWN,
                einkActive = true,
                volumeButtonNavigation = false,
                audioActive = true,
            ),
        )

        assertEquals(
            ReaderPageKeyDirection.BACKWARD,
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_DPAD_LEFT,
                einkActive = true,
                volumeButtonNavigation = false,
                audioActive = true,
            ),
        )
    }

    @Test
    fun einkVolumeKeysStillRespectAudioPlayback() {
        assertNull(
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_VOLUME_DOWN,
                einkActive = true,
                volumeButtonNavigation = true,
                audioActive = true,
            ),
        )

        assertEquals(
            ReaderPageKeyDirection.BACKWARD,
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_VOLUME_DOWN,
                einkActive = true,
                volumeButtonNavigation = true,
                audioActive = false,
            ),
        )
    }
}
