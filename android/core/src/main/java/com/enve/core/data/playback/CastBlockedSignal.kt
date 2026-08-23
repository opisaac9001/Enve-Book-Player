package com.enve.core.data.playback

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

object CastBlockedSignal {
    private val _events = MutableSharedFlow<String>(extraBufferCapacity = 1)
    val events: SharedFlow<String> = _events.asSharedFlow()

    fun emit(bookTitle: String?) {
        _events.tryEmit(bookTitle.orEmpty())
    }
}
