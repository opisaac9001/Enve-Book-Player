package com.enve.app.automation

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.media3.session.MediaController
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionToken
import com.enve.app.playback.PlaybackService
import com.enve.engine.playback.PlaybackAutomationContract

internal enum class PlaybackAutomationCommand(val action: String) {
    PLAY(PlaybackAutomationContract.ACTION_PLAY),
    PAUSE(PlaybackAutomationContract.ACTION_PAUSE),
    TOGGLE_PLAYBACK(PlaybackAutomationContract.ACTION_TOGGLE_PLAYBACK),
    STOP(PlaybackAutomationContract.ACTION_STOP),
    SKIP_FORWARD(PlaybackAutomationContract.ACTION_SKIP_FORWARD),
    SKIP_BACKWARD(PlaybackAutomationContract.ACTION_SKIP_BACKWARD),
    NEXT_CHAPTER(PlaybackAutomationContract.ACTION_NEXT_CHAPTER),
    PREVIOUS_CHAPTER(PlaybackAutomationContract.ACTION_PREVIOUS_CHAPTER),
    SEEK_TO(PlaybackAutomationContract.ACTION_SEEK_TO),
    SEEK_BY(PlaybackAutomationContract.ACTION_SEEK_BY),
    SET_SPEED(PlaybackAutomationContract.ACTION_SET_SPEED),
    ;

    companion object {
        fun fromAction(action: String?): PlaybackAutomationCommand? =
            entries.firstOrNull { it.action == action }
    }
}

class PlaybackAutomationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val command = PlaybackAutomationCommand.fromAction(intent.action) ?: return
        val pendingResult = goAsync()
        val appContext = context.applicationContext
        val sessionToken = SessionToken(
            appContext,
            ComponentName(appContext, PlaybackService::class.java),
        )
        val controllerFuture = MediaController.Builder(appContext, sessionToken).buildAsync()
        controllerFuture.addListener(
            {
                try {
                    execute(controllerFuture.get(), command, intent)
                } catch (e: Exception) {
                    Log.w(TAG, "Playback command failed", e)
                } finally {
                    MediaController.releaseFuture(controllerFuture)
                    pendingResult.finish()
                }
            },
            ContextCompat.getMainExecutor(appContext),
        )
    }

    private fun execute(
        controller: MediaController,
        command: PlaybackAutomationCommand,
        intent: Intent,
    ) {
        when (command) {
            PlaybackAutomationCommand.PLAY -> controller.play()
            PlaybackAutomationCommand.PAUSE -> controller.pause()
            PlaybackAutomationCommand.TOGGLE_PLAYBACK -> {
                if (controller.playWhenReady) controller.pause() else controller.play()
            }
            PlaybackAutomationCommand.STOP -> controller.stop()
            PlaybackAutomationCommand.SKIP_FORWARD -> controller.seekForward()
            PlaybackAutomationCommand.SKIP_BACKWARD -> controller.seekBack()
            PlaybackAutomationCommand.NEXT_CHAPTER -> controller.sendCustomCommand(
                SessionCommand(PlaybackAutomationContract.COMMAND_NEXT_CHAPTER, Bundle.EMPTY),
                Bundle.EMPTY,
            )
            PlaybackAutomationCommand.PREVIOUS_CHAPTER -> controller.sendCustomCommand(
                SessionCommand(PlaybackAutomationContract.COMMAND_PREVIOUS_CHAPTER, Bundle.EMPTY),
                Bundle.EMPTY,
            )
            PlaybackAutomationCommand.SEEK_TO -> {
                val positionMs = intent.numericExtra(PlaybackAutomationContract.EXTRA_POSITION_MS)
                    ?.toLong()
                    ?.coerceAtLeast(0L)
                    ?: return
                val args = Bundle().apply {
                    putLong(
                        PlaybackAutomationContract.EXTRA_POSITION_MS,
                        positionMs,
                    )
                }
                controller.sendCustomCommand(
                    SessionCommand(PlaybackAutomationContract.COMMAND_SEEK_TO, Bundle.EMPTY),
                    args,
                )
            }
            PlaybackAutomationCommand.SEEK_BY -> {
                val offsetMs = intent.numericExtra(PlaybackAutomationContract.EXTRA_OFFSET_MS)
                    ?.toLong()
                    ?: return
                val args = Bundle().apply {
                    putLong(
                        PlaybackAutomationContract.EXTRA_OFFSET_MS,
                        offsetMs,
                    )
                }
                controller.sendCustomCommand(
                    SessionCommand(PlaybackAutomationContract.COMMAND_SEEK_BY, Bundle.EMPTY),
                    args,
                )
            }
            PlaybackAutomationCommand.SET_SPEED -> {
                val speed = intent.numericExtra(PlaybackAutomationContract.EXTRA_SPEED)?.toFloat()
                    ?: return
                if (speed.isFinite() && speed in MIN_SPEED..MAX_SPEED) controller.setPlaybackSpeed(speed)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun Intent.numericExtra(key: String): Number? = extras?.get(key) as? Number

    private companion object {
        const val TAG = "PlaybackAutomation"
        const val MIN_SPEED = 0.5f
        const val MAX_SPEED = 3.0f
    }
}
