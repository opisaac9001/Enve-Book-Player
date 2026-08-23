package com.enve.wear.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class WearBook(
    val key: String,
    val title: String,
    val author: String? = null,
    val progress: Float = 0f,
)

@Serializable
data class WearState(
    val hasMedia: Boolean = false,
    val isPlaying: Boolean = false,
    val title: String? = null,
    val author: String? = null,
    val positionMs: Long = 0L,
    val durationMs: Long = 0L,
    val speed: Float = 1f,
    val sleepRemainingSec: Long? = null,
    val recentBooks: List<WearBook> = emptyList(),
    val lastSleepMs: Long? = null,
    val averageSleepMs: Long? = null,
    val sleepNights: Int = 0,
    val updatedAtMs: Long = 0L,
)

object WearProtocol {
    const val STATE_PATH = "/enve/state"
    const val REQUEST_STATE_PATH = "/enve/state/request"
    const val TOGGLE_PATH = "/enve/playback/toggle"
    const val BACK_PATH = "/enve/playback/back"
    const val FORWARD_PATH = "/enve/playback/forward"
    const val OPEN_BOOK_PATH = "/enve/playback/open"
    const val START_SLEEP_PATH = "/enve/sleep/start"
    const val CANCEL_SLEEP_PATH = "/enve/sleep/cancel"

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    fun encode(state: WearState): ByteArray = json.encodeToString(WearState.serializer(), state).encodeToByteArray()

    fun decode(bytes: ByteArray): WearState = json.decodeFromString(WearState.serializer(), bytes.decodeToString())
}
