package com.enve.engine.playback

object PlaybackAutomationContract {
    const val ACTION_PLAY = "com.enve.app.action.PLAY"
    const val ACTION_PAUSE = "com.enve.app.action.PAUSE"
    const val ACTION_TOGGLE_PLAYBACK = "com.enve.app.action.TOGGLE_PLAYBACK"
    const val ACTION_STOP = "com.enve.app.action.STOP"
    const val ACTION_SKIP_FORWARD = "com.enve.app.action.SKIP_FORWARD"
    const val ACTION_SKIP_BACKWARD = "com.enve.app.action.SKIP_BACKWARD"
    const val ACTION_NEXT_CHAPTER = "com.enve.app.action.NEXT_CHAPTER"
    const val ACTION_PREVIOUS_CHAPTER = "com.enve.app.action.PREVIOUS_CHAPTER"
    const val ACTION_SEEK_TO = "com.enve.app.action.SEEK_TO"
    const val ACTION_SEEK_BY = "com.enve.app.action.SEEK_BY"
    const val ACTION_SET_SPEED = "com.enve.app.action.SET_SPEED"

    const val EXTRA_POSITION_MS = "position_ms"
    const val EXTRA_OFFSET_MS = "offset_ms"
    const val EXTRA_SPEED = "speed"

    const val COMMAND_NEXT_CHAPTER = "enve.player.nextChapter"
    const val COMMAND_PREVIOUS_CHAPTER = "enve.player.previousChapter"
    const val COMMAND_CYCLE_PLAYBACK_SPEED = "enve.player.cyclePlaybackSpeed"
    const val COMMAND_ADD_BOOKMARK = "enve.player.addBookmark"
    const val COMMAND_SEEK_TO = "enve.player.seekTo"
    const val COMMAND_SEEK_BY = "enve.player.seekBy"
}
