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
    fun standardDevicesUseBluetoothKeyboardPageKeys() {
        assertEquals(
            ReaderPageKeyDirection.FORWARD,
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_PAGE_DOWN,
                volumeButtonNavigation = false,
                audioActive = true,
            ),
        )

        assertEquals(
            ReaderPageKeyDirection.BACKWARD,
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_DPAD_LEFT,
                volumeButtonNavigation = false,
                audioActive = true,
            ),
        )
    }

    @Test
    fun volumeKeysRequireOptInAndIdleAudio() {
        assertEquals(
            ReaderPageKeyDirection.FORWARD,
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_VOLUME_UP,
                volumeButtonNavigation = true,
                audioActive = false,
            ),
        )

        assertNull(
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_VOLUME_UP,
                volumeButtonNavigation = true,
                audioActive = true,
            ),
        )

        assertNull(
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_VOLUME_UP,
                volumeButtonNavigation = false,
                audioActive = false,
            ),
        )
    }

    @Test
    fun mediaKeysDoNotStealActiveAudioControls() {
        assertEquals(
            ReaderPageKeyDirection.FORWARD,
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_MEDIA_NEXT,
                volumeButtonNavigation = false,
                audioActive = false,
            ),
        )

        assertNull(
            ReaderHardwareKeyPolicy.directionFor(
                keyCode = KeyEvent.KEYCODE_MEDIA_PREVIOUS,
                volumeButtonNavigation = false,
                audioActive = true,
            ),
        )
    }
}
