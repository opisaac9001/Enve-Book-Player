package com.enve.app.ui.screens

import android.view.KeyEvent

enum class ReaderPageKeyDirection {
    FORWARD,
    BACKWARD,
}

object ReaderHardwareKeyPolicy {
    fun shouldTriggerTurn(action: Int, repeatCount: Int): Boolean =
        action == KeyEvent.ACTION_DOWN && repeatCount == 0

    fun directionFor(
        keyCode: Int,
        volumeButtonNavigation: Boolean,
        audioActive: Boolean,
    ): ReaderPageKeyDirection? {
        when (keyCode) {
            KeyEvent.KEYCODE_PAGE_DOWN,
            KeyEvent.KEYCODE_DPAD_RIGHT,
            KeyEvent.KEYCODE_BUTTON_R1,
            KeyEvent.KEYCODE_BUTTON_R2,
            KeyEvent.KEYCODE_BUTTON_Z,
            KeyEvent.KEYCODE_F2 -> return ReaderPageKeyDirection.FORWARD

            KeyEvent.KEYCODE_PAGE_UP,
            KeyEvent.KEYCODE_DPAD_LEFT,
            KeyEvent.KEYCODE_BUTTON_L1,
            KeyEvent.KEYCODE_BUTTON_L2,
            KeyEvent.KEYCODE_BUTTON_Y,
            KeyEvent.KEYCODE_F1 -> return ReaderPageKeyDirection.BACKWARD

            KeyEvent.KEYCODE_MEDIA_NEXT -> if (!audioActive) return ReaderPageKeyDirection.FORWARD
            KeyEvent.KEYCODE_MEDIA_PREVIOUS -> if (!audioActive) return ReaderPageKeyDirection.BACKWARD
        }

        if (!volumeButtonNavigation || audioActive) return null
        return when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> ReaderPageKeyDirection.FORWARD
            KeyEvent.KEYCODE_VOLUME_DOWN -> ReaderPageKeyDirection.BACKWARD
            else -> null
        }
    }
}
