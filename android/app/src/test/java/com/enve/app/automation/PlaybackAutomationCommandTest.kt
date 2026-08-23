package com.enve.app.automation

import com.enve.engine.playback.PlaybackAutomationContract
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlaybackAutomationCommandTest {
    @Test
    fun resolvesEveryPublicAction() {
        val actions = mapOf(
            PlaybackAutomationContract.ACTION_PLAY to PlaybackAutomationCommand.PLAY,
            PlaybackAutomationContract.ACTION_PAUSE to PlaybackAutomationCommand.PAUSE,
            PlaybackAutomationContract.ACTION_TOGGLE_PLAYBACK to PlaybackAutomationCommand.TOGGLE_PLAYBACK,
            PlaybackAutomationContract.ACTION_STOP to PlaybackAutomationCommand.STOP,
            PlaybackAutomationContract.ACTION_SKIP_FORWARD to PlaybackAutomationCommand.SKIP_FORWARD,
            PlaybackAutomationContract.ACTION_SKIP_BACKWARD to PlaybackAutomationCommand.SKIP_BACKWARD,
            PlaybackAutomationContract.ACTION_NEXT_CHAPTER to PlaybackAutomationCommand.NEXT_CHAPTER,
            PlaybackAutomationContract.ACTION_PREVIOUS_CHAPTER to PlaybackAutomationCommand.PREVIOUS_CHAPTER,
            PlaybackAutomationContract.ACTION_SEEK_TO to PlaybackAutomationCommand.SEEK_TO,
            PlaybackAutomationContract.ACTION_SEEK_BY to PlaybackAutomationCommand.SEEK_BY,
            PlaybackAutomationContract.ACTION_SET_SPEED to PlaybackAutomationCommand.SET_SPEED,
        )

        actions.forEach { (action, expected) ->
            assertEquals(expected, PlaybackAutomationCommand.fromAction(action))
        }
    }

    @Test
    fun rejectsUnknownActions() {
        assertNull(PlaybackAutomationCommand.fromAction(null))
        assertNull(PlaybackAutomationCommand.fromAction("com.enve.app.action.UNKNOWN"))
    }
}
