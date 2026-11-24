package com.enve.app.playback

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaBrowser
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.profiles.DaggerProfileRuntimeComponent
import com.enve.app.profiles.ProfileResources
import com.enve.app.profiles.ProfileRuntimeComponent
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@androidx.annotation.OptIn(UnstableApi::class)
class SleepTimerPreferenceTest {
    @Test
    fun chapterTimerHonorsDisabledFadeAndPausesAtTheBoundary() = fixture { component, browser ->
        val session = component.playerSession()
        val end = component.audioPlayback().state.value.currentPositionMs / 1000 + 4
        session.startChapterSleepTimer(end)
        await { session.sleepRemainingSec.value != null }
        while (session.sleepRemainingSec.value != null) {
            withContext(Dispatchers.Main) { assertEquals(1f, browser.volume, 0.001f) }
            delay(100)
        }
        await { withContext(Dispatchers.Main) { !browser.isPlaying } }
        withContext(Dispatchers.Main) {
            assertFalse(browser.playWhenReady)
            assertTrue(browser.currentPosition >= end * 1000)
            assertTrue(browser.currentPosition < (end + 2) * 1000)
            assertEquals(1f, browser.volume, 0.001f)
        }
    }

    @Test
    fun chapterTimerRespondsToFadeChangesAndCancelRestoresVolume() = fixture { component, browser ->
        val session = component.playerSession()
        session.startChapterSleepTimer(component.audioPlayback().state.value.currentPositionMs / 1000 + 25)
        await { session.sleepRemainingSec.value != null }
        delay(500)
        withContext(Dispatchers.Main) { assertEquals(1f, browser.volume, 0.001f) }
        component.preferences().setSleepTimerFade(true)
        await { withContext(Dispatchers.Main) { browser.volume < 0.9f } }
        component.preferences().setSleepTimerFade(false)
        await { withContext(Dispatchers.Main) { browser.volume == 1f } }
        component.preferences().setSleepTimerFade(true)
        await { withContext(Dispatchers.Main) { browser.volume < 0.9f } }
        session.cancelSleepTimer()
        await { withContext(Dispatchers.Main) { browser.volume == 1f } }
        withContext(Dispatchers.Main) { assertTrue(browser.isPlaying) }
    }

    @Test
    fun timedSleepHonorsDisabledFadeAndRespondsToPreferenceChanges() = fixture { component, browser ->
        val session = component.playerSession()
        session.startSleepTimer(1)
        withTimeout(40_000) {
            while ((session.sleepRemainingSec.value ?: 60L) > 28L) delay(100)
        }
        withContext(Dispatchers.Main) { assertEquals(1f, browser.volume, 0.001f) }
        component.preferences().setSleepTimerFade(true)
        await { withContext(Dispatchers.Main) { browser.volume < 0.95f } }
        component.preferences().setSleepTimerFade(false)
        await { withContext(Dispatchers.Main) { browser.volume == 1f } }
        session.cancelSleepTimer()
        withContext(Dispatchers.Main) { assertTrue(browser.isPlaying) }
    }

    private fun fixture(action: suspend (ProfileRuntimeComponent, MediaBrowser) -> Unit) = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val resources = ProfileResources.open(context, UUID.randomUUID().toString())
        val component = DaggerProfileRuntimeComponent.factory().create(resources)
        val manager = component.audioPlayback()
        resources.preferences.setSleepTimerFade(false)
        val future = withContext(Dispatchers.Main) {
            MediaBrowser.Builder(context, SessionToken(context, ComponentName(context, PlaybackService::class.java)))
                .setApplicationLooper(Looper.getMainLooper()).buildAsync()
        }
        val browser = withContext(Dispatchers.IO) { future.get(15, TimeUnit.SECONDS) }
        val originalVolume = withContext(Dispatchers.Main) { browser.volume }
        try {
            val audio = File(resources.locations.cacheDirectory, "sleep-timer.wav")
            val pcmSize = 1_440_000
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
                .put("RIFF".toByteArray()).putInt(36 + pcmSize).put("WAVEfmt ".toByteArray())
                .putInt(16).putShort(1).putShort(1).putInt(8000).putInt(16000)
                .putShort(2).putShort(16).put("data".toByteArray()).putInt(pcmSize).array()
            audio.parentFile!!.mkdirs()
            audio.outputStream().use { it.write(header); it.write(ByteArray(pcmSize)) }
            withContext(Dispatchers.Main) {
                browser.pause()
                browser.stop()
                browser.clearMediaItems()
                browser.volume = 1f
                manager.play(Uri.fromFile(audio).toString(), "sleep-test", "Sleep timer test", null, null)
            }
            await { manager.state.value.isPlaying && manager.state.value.currentPositionMs > 100L }
            withTimeout(60_000) { action(component, browser) }
        } finally {
            component.playerSession().cancelSleepTimer()
            withContext(NonCancellable + Dispatchers.Main) {
                manager.release()
                browser.pause()
                browser.stop()
                browser.clearMediaItems()
                browser.volume = originalVolume
                browser.release()
                MediaController.releaseFuture(future)
            }
            resources.close()
            resources.locations.filesDirectory.deleteRecursively()
            resources.locations.cacheDirectory.deleteRecursively()
            resources.locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }

    private suspend fun await(condition: suspend () -> Boolean) = withTimeout(10_000) {
        while (!condition()) delay(50)
    }
}
