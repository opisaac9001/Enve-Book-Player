package com.enve.wear

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import com.enve.wear.protocol.WearProtocol
import com.enve.wear.protocol.WearState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

data class WearUiState(
    val phoneAvailable: Boolean? = null,
    val content: WearState = WearState(),
)

class WearViewModel(application: Application) : AndroidViewModel(application) {
    private val _state = MutableStateFlow(WearUiState())
    val state = _state.asStateFlow()
    private val connection = WearConnection(
        context = application,
        onState = { content -> _state.update { it.copy(phoneAvailable = true, content = content) } },
        onAvailability = { available -> _state.update { it.copy(phoneAvailable = available) } },
    )

    fun start() = connection.start()
    fun stop() = connection.stop()
    fun retry() = connection.send(WearProtocol.REQUEST_STATE_PATH)
    fun toggle() = connection.send(WearProtocol.TOGGLE_PATH)
    fun skipBack() = connection.send(WearProtocol.BACK_PATH)
    fun skipForward() = connection.send(WearProtocol.FORWARD_PATH)
    fun openBook(key: String) = connection.send(WearProtocol.OPEN_BOOK_PATH, key.encodeToByteArray())
    fun startSleep() = connection.send(WearProtocol.START_SLEEP_PATH, "30".encodeToByteArray())
    fun cancelSleep() = connection.send(WearProtocol.CANCEL_SLEEP_PATH)
}
