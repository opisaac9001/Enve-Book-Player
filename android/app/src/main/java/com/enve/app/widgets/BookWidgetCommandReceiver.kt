package com.enve.app.widgets

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class BookWidgetCommandReceiver : BroadcastReceiver() {
    @EntryPoint
    @InstallIn(SingletonComponent::class)
    interface PlaybackEntryPoint {
        fun profiles(): com.enve.app.profiles.ProfileSwitchCoordinator
    }

    override fun onReceive(context: Context, intent: Intent) {
        val expectedKey = intent.getStringExtra("book_key") ?: return
        val entry = EntryPointAccessors.fromApplication(context.applicationContext, PlaybackEntryPoint::class.java)
        val coordinator = entry.profiles()
        val runtime = coordinator.activeRuntime.value ?: return
        if (coordinator.state.value.locked || coordinator.state.value.switching) return
        val expectedProfile = intent.getStringExtra(com.enve.app.profiles.ProfileActivityBinding.EXTRA_PROFILE_ID)
        val expectedGeneration = intent.getLongExtra(com.enve.app.profiles.ProfileActivityBinding.EXTRA_GENERATION, -1L)
        if (coordinator.state.value.enabled && (expectedProfile != runtime.profileId || expectedGeneration != runtime.generation)) return
        val playback = runtime.component.playback()
        val command = intent.getStringExtra("command")
        intent.getStringExtra("read_along_session")?.let { sessionId ->
            val readAloud = runtime.component.readAloud()
            val state = readAloud.state.value
            if (command == "toggle" && state.sessionId == sessionId && state.matchesBook(expectedKey)) {
                if (state.isPlaying) readAloud.pause(sessionId) else readAloud.play(sessionId)
            }
            return
        }
        if (playback.nowPlaying.value?.bookKey == expectedKey && playback.transport.value.hasMedia) {
            when (command) {
                "back" -> playback.skipBackward()
                "toggle" -> playback.togglePlayPause()
                "forward" -> playback.skipForward()
            }
        } else if (command == "toggle") {
            val pending = goAsync()
            runtime.component.resources().scope.launch(Dispatchers.Main) {
                val book = runtime.component.library().bookByKeyFlow(expectedKey).first()
                        ?.takeIf { it.supportsListening() } ?: return@launch
                    if (playback.queue.value.any { it.book.uniqueKey == expectedKey }) {
                        playback.playQueued(expectedKey)
                    } else {
                        playback.open(book)
                    }
            }.invokeOnCompletion { pending.finish() }
        }
    }
}
