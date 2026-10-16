package com.enve.app.playback

import android.content.ComponentName
import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.profiles.ProfileActivityBinding
import dagger.hilt.android.EntryPointAccessors
import com.enve.app.MainActivity
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeNoException
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class StreamingInterruptionTest {
    @Test
    fun streamingResumesAfterItsBufferRunsOut() = verifyOutage(pauseBeforeRestoring = false)

    @Test
    fun pausedStreamingStaysPausedWhenNetworkReturns() = verifyOutage(pauseBeforeRestoring = true)

    @Test
    fun droppedConnectionRecoversWithoutResettingPosition() = verifyOutage(pauseBeforeRestoring = false, dropConnection = true)

    private fun verifyOutage(pauseBeforeRestoring: Boolean, dropConnection: Boolean = false) = runBlocking {
        val key = "${UUID.randomUUID()}.wav"
        requireServer(key)
        val player = connect()
        try {
            withContext(Dispatchers.Main) {
                player.setMediaItem(MediaItem.Builder().setMediaId(key)
                    .setUri("http://127.0.0.1:18763/stream/$key").build())
                player.prepare()
                player.play()
            }
            await { player.isPlaying && player.currentPosition > 1000 }
            control(key, "stall")
            await { player.playbackState == Player.STATE_BUFFERING }
            val stalledAt = withContext(Dispatchers.Main) { player.currentPosition }
            assertTrue("The fixture must actually exhaust its buffer", stalledAt in 1..30000)
            delay(1000)
            withContext(Dispatchers.Main) {
                assertEquals(stalledAt, player.currentPosition)
                assertNull(player.playerError)
                assertEquals(key, player.currentMediaItem?.mediaId)
                if (pauseBeforeRestoring) player.pause()
            }
            if (dropConnection) {
                control(key, "drop")
                delay(1000)
            }
            control(key, "online")
            if (pauseBeforeRestoring) {
                await { player.playbackState == Player.STATE_READY }
                delay(1000)
                withContext(Dispatchers.Main) {
                    assertFalse(player.isPlaying)
                    assertEquals(stalledAt, player.currentPosition)
                    player.play()
                }
            }
            await { player.isPlaying && player.currentPosition > stalledAt + 1000 }
            withContext(Dispatchers.Main) {
                assertEquals(key, player.currentMediaItem?.mediaId)
                assertTrue(player.currentPosition < stalledAt + 8000)
            }
        } finally {
            control(key, "online")
            withContext(Dispatchers.Main) { player.stop(); player.clearMediaItems(); player.release() }
        }
    }

    @Test
    fun initialConnectionFailureCanBeRetriedAfterNetworkReturns() = runBlocking {
        val key = "${UUID.randomUUID()}.wav"
        requireServer(key)
        val player = connect()
        try {
            control(key, "drop")
            withContext(Dispatchers.Main) {
                player.setMediaItem(MediaItem.Builder().setMediaId(key)
                    .setUri("http://127.0.0.1:18763/stream/$key").build())
                player.prepare()
                player.play()
            }
            await { player.playerError != null }
            withContext(Dispatchers.Main) { assertEquals(0L, player.currentPosition) }
            val context = ApplicationProvider.getApplicationContext<Context>()
            val profiles = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
            val manager = checkNotNull(profiles.activeRuntime.value).component.audioPlayback()
            withContext(Dispatchers.Main) { manager.connect() }
            await { manager.state.value.mediaId == key && manager.state.value.errorMessage != null }
            control(key, "online")
            withContext(Dispatchers.Main) { manager.togglePlayPause() }
            await { player.isPlaying && player.currentPosition > 1000 }
            withContext(Dispatchers.Main) { assertNull(player.playerError) }
        } finally {
            control(key, "online")
            withContext(Dispatchers.Main) { player.stop(); player.clearMediaItems(); player.release() }
        }
    }

    private suspend fun connect(): MediaController {
        val context = ApplicationProvider.getApplicationContext<Context>()
        ActivityScenario.launch(MainActivity::class.java).close()
        val future = withContext(Dispatchers.Main) {
            MediaController.Builder(context, SessionToken(context, ComponentName(context, PlaybackService::class.java))).buildAsync()
        }
        return withContext(Dispatchers.IO) { future.get(10, TimeUnit.SECONDS) }
    }

    private suspend fun requireServer(key: String) {
        try { control(key, "online") } catch (error: Exception) { assumeNoException(error) }
    }

    private suspend fun control(key: String, mode: String) = withContext(Dispatchers.IO) {
        val connection = URL("http://127.0.0.1:18763/control/$key/$mode").openConnection() as HttpURLConnection
        connection.connectTimeout = 2000
        connection.readTimeout = 2000
        try {
            assertEquals(200, connection.responseCode)
            connection.inputStream.use { it.readBytes() }
            Unit
        } finally { connection.disconnect() }
    }

    private suspend fun await(condition: () -> Boolean) {
        withTimeout(30000) {
            while (!withContext(Dispatchers.Main) { condition() }) delay(100)
        }
    }
}
