package com.enve.app.wear

import com.enve.core.data.model.AppMediaType
import com.enve.engine.library.LibraryFacade
import com.enve.engine.playback.PlaybackFacade
import com.enve.engine.playback.PlayerSessionFacade
import com.enve.engine.sleep.SleepDataAccess
import com.enve.engine.sleep.SleepDataFacade
import com.enve.wear.protocol.WearBook
import com.enve.wear.protocol.WearProtocol
import com.enve.wear.protocol.WearState
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.PutDataRequest
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

@AndroidEntryPoint
class WearCompanionService : WearableListenerService() {
    @Inject lateinit var playback: PlaybackFacade
    @Inject lateinit var session: PlayerSessionFacade
    @Inject lateinit var library: LibraryFacade
    @Inject lateinit var sleepData: SleepDataFacade

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onMessageReceived(event: MessageEvent) {
        scope.launch {
            when (event.path) {
                WearProtocol.TOGGLE_PATH -> playback.togglePlayPause()
                WearProtocol.BACK_PATH -> playback.skipBackward()
                WearProtocol.FORWARD_PATH -> playback.skipForward()
                WearProtocol.OPEN_BOOK_PATH -> openBook(event.data.decodeToString())
                WearProtocol.START_SLEEP_PATH -> session.startSleepTimer(
                    event.data.decodeToString().toIntOrNull()?.coerceIn(1, 120) ?: 30,
                )
                WearProtocol.CANCEL_SLEEP_PATH -> session.cancelSleepTimer()
                WearProtocol.REQUEST_STATE_PATH -> Unit
                else -> return@launch
            }
            publishState()
        }
    }

    private suspend fun openBook(key: String) {
        val book = library.bookByKeyFlow(key).first() ?: return
        if (book.mediaType == AppMediaType.AUDIOBOOK || book.hasAudio) playback.open(book)
    }

    private suspend fun publishState() {
        val (transport, nowPlaying) = coroutineScope {
            val transportSnapshot = async {
                withTimeoutOrNull(1_500) { playback.transport.drop(1).first() } ?: playback.transport.value
            }
            val nowPlayingSnapshot = async {
                withTimeoutOrNull(1_500) { playback.nowPlaying.drop(1).first() } ?: playback.nowPlaying.value
            }
            transportSnapshot.await() to nowPlayingSnapshot.await()
        }
        val recent = library.continueBooks.first()
            .filter { it.mediaType == AppMediaType.AUDIOBOOK || it.hasAudio }
            .take(5)
            .map { book ->
                WearBook(
                    key = book.uniqueKey,
                    title = book.title,
                    author = book.author,
                    progress = book.progress,
                )
            }
        val sleep = try {
            sleepData.load(14)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }
        val nights = sleep?.periods.orEmpty().filterNot { it.isNap }.sortedByDescending { it.startTimeMs }
        val state = WearState(
            hasMedia = transport.hasMedia,
            isPlaying = transport.isPlaying,
            title = nowPlaying?.title,
            author = nowPlaying?.author,
            positionMs = transport.positionMs,
            durationMs = transport.durationMs,
            speed = transport.speed,
            sleepRemainingSec = session.sleepRemainingSec.value,
            recentBooks = recent,
            lastSleepMs = nights.firstOrNull()?.totalSleepMs,
            averageSleepMs = nights.take(7).map { it.totalSleepMs }.takeIf { it.isNotEmpty() }?.average()?.toLong(),
            sleepNights = if (sleep?.access == SleepDataAccess.AVAILABLE) nights.size else 0,
            updatedAtMs = System.currentTimeMillis(),
        )
        val request = PutDataRequest.create(WearProtocol.STATE_PATH).apply {
            data = WearProtocol.encode(state)
            setUrgent()
        }
        Wearable.getDataClient(this).putDataItem(request)
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
