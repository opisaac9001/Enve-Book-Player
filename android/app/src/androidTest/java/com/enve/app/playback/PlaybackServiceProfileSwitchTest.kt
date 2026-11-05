package com.enve.app.playback

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.Uri
import android.os.IBinder
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaBrowser
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.core.data.local.AdultPinResult
import com.enve.core.data.local.FamilyProfileRole
import com.enve.core.data.local.FamilyProfileStore
import dagger.hilt.android.EntryPointAccessors
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@androidx.annotation.OptIn(UnstableApi::class)
class PlaybackServiceProfileSwitchTest {
    @Test
    fun boundServiceAcceptsUnlockedAndSwitchedProfilesWithoutRevivingOldControllers() = runBlocking {
        assumeTrue(
            "Requires profilePlaybackCleanFixture=true and dedicated debug data cleared before and after this fixture.",
            InstrumentationRegistry.getArguments().getString("profilePlaybackCleanFixture") == "true",
        )
        val context = ApplicationProvider.getApplicationContext<Context>()
        val profiles = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        val catalog = FamilyProfileStore(context)
        check(!catalog.hasAdultPin) { "Run this fixture with clean debug test data." }
        val pin = "276410"
        assertEquals(AdultPinResult.Accepted, catalog.setAdultPin(pin))
        val browsers = mutableListOf<MediaBrowser>()
        val bound = CompletableDeferred<Unit>()
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) { bound.complete(Unit) }
            override fun onServiceDisconnected(name: ComponentName) = Unit
        }
        var serviceBound = false
        var targetId: String? = null
        val audio = File(context.cacheDir, "profile-switch-${UUID.randomUUID()}.wav")
        writeAudio(audio)
        profiles.initialize()
        val original = checkNotNull(profiles.activeRuntime.value)
        val originalProfile = profiles.state.value.profiles.first { it.id == original.profileId }
        check(originalProfile.role == FamilyProfileRole.ADULT && !originalProfile.requiresPin)
        val wasEnabled = profiles.state.value.enabled
        try {
            if (!wasEnabled) profiles.setupOwner(originalProfile.name)
            profiles.setProfilePinRequired(original.profileId, true, pin)
            profiles.onBackground()
            assertTrue(profiles.state.value.locked)
            serviceBound = withContext(Dispatchers.Main) {
                context.bindService(
                    Intent(context, PlaybackService::class.java).setAction(MediaLibraryService.SERVICE_INTERFACE),
                    connection,
                    Context.BIND_AUTO_CREATE,
                )
            }
            assertTrue(serviceBound)
            withTimeout(10_000) { bound.await() }
            val lockedFailure = try {
                connect(context, "locked").also(browsers::add)
                null
            } catch (error: AssertionError) {
                error
            }
            assertTrue(
                "A locked profile must reject the playback connection",
                generateSequence<Throwable>(lockedFailure) { it.cause }.any { it is SecurityException },
            )

            ActivityScenario.launch(MainActivity::class.java).use {
                profiles.switchProfile(original.profileId, pin)
                assertFalse(profiles.state.value.locked)
                val initial = connect(context, "initial after locked bootstrap").also(browsers::add)

                val beforeRelock = checkNotNull(profiles.activeRuntime.value)
                profiles.onBackground()
                assertTrue(profiles.state.value.locked)
                profiles.switchProfile(original.profileId, pin)
                val unlocked = checkNotNull(profiles.activeRuntime.value)
                assertTrue(unlocked.generation > beforeRelock.generation)
                assertTrue(unlocked.component === beforeRelock.component)
                assertFalse(profiles.state.value.locked)
                verifyPlayback(initial, audio, "existing-controller-fixture-${UUID.randomUUID()}")
                connect(context, "unlocked").also(browsers::add)

                val target = profiles.addProfile("Playback switch fixture", FamilyProfileRole.ADULT)
                targetId = target.id
                profiles.switchProfile(target.id)
                assertEquals(target.id, profiles.activeRuntime.value?.profileId)
                val current = connect(context, "switched").also(browsers::add)
                val mediaId = "profile-switch-fixture-${UUID.randomUUID()}"
                verifyPlayback(current, audio, mediaId)
                await { withContext(Dispatchers.Main) { !initial.isConnected } }
                withContext(Dispatchers.Main) { initial.play() }
                delay(300)
                withContext(Dispatchers.Main) {
                    assertFalse(current.isPlaying)
                    assertFalse(current.playWhenReady)
                    assertEquals(mediaId, current.currentMediaItem?.mediaId)
                }
            }
        } finally {
            withContext(NonCancellable) {
                withContext(Dispatchers.Main) {
                    browsers.forEach { browser ->
                        if (browser.isConnected) { browser.stop(); browser.clearMediaItems() }
                        browser.release()
                    }
                    if (serviceBound) context.unbindService(connection)
                }
                if (profiles.state.value.locked) profiles.verifyAdultPin(pin)
                profiles.setProfilePinRequired(original.profileId, false, pin)
                profiles.switchProfile(original.profileId)
                targetId?.let { profiles.removeProfile(it) }
                if (!wasEnabled) profiles.disableProfiles()
            }
            audio.delete()
        }
    }

    private suspend fun verifyPlayback(browser: MediaBrowser, audio: File, mediaId: String) {
        withContext(Dispatchers.Main) {
            browser.setMediaItem(MediaItem.Builder().setMediaId(mediaId).setUri(Uri.fromFile(audio)).build())
            browser.prepare()
            browser.play()
        }
        await { withContext(Dispatchers.Main) { browser.isPlaying && browser.currentPosition > 250L } }
        withContext(Dispatchers.Main) { browser.pause() }
        await { withContext(Dispatchers.Main) { !browser.isPlaying && !browser.playWhenReady } }
    }

    private suspend fun connect(context: Context, stage: String): MediaBrowser {
        val future = withContext(Dispatchers.Main) {
            MediaBrowser.Builder(context, SessionToken(context, ComponentName(context, PlaybackService::class.java)))
                .setApplicationLooper(Looper.getMainLooper())
                .buildAsync()
        }
        return try {
            withContext(Dispatchers.IO) { future.get(15, TimeUnit.SECONDS) }
        } catch (error: Exception) {
            withContext(NonCancellable + Dispatchers.Main) { MediaController.releaseFuture(future) }
            throw AssertionError("The $stage profile playback controller could not connect", error)
        }
    }

    private suspend fun await(condition: suspend () -> Boolean) = withTimeout(20_000) {
        while (!condition()) delay(50)
    }

    private fun writeAudio(file: File) {
        val pcmSize = 480_000
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            .put("RIFF".toByteArray()).putInt(36 + pcmSize).put("WAVEfmt ".toByteArray())
            .putInt(16).putShort(1).putShort(1).putInt(8000).putInt(16000)
            .putShort(2).putShort(16).put("data".toByteArray()).putInt(pcmSize).array()
        file.outputStream().use { output -> output.write(header); output.write(ByteArray(pcmSize)) }
    }
}
