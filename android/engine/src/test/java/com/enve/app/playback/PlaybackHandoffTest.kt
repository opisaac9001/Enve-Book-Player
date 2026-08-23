package com.enve.app.playback

import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy

class PlaybackHandoffTest {
    @Test
    fun appliesPlayIntentBeforeLoadingMedia() {
        val items = listOf(mediaItem("one"), mediaItem("two"))
        val source = RecordingPlayer(
            items = items,
            currentIndex = 1,
            currentPositionMs = 42_000L,
            playWhenReady = true,
            repeatMode = Player.REPEAT_MODE_ALL,
            shuffleModeEnabled = true,
            playbackParameters = PlaybackParameters(1.5f),
        )
        val target = RecordingPlayer()

        PlaybackHandoff.capture(source.player).applyTo(target.player)

        assertEquals(items, target.items)
        assertEquals(1, target.currentIndex)
        assertEquals(42_000L, target.currentPositionMs)
        assertEquals(PlaybackParameters(1.5f), target.playbackParameters)
        assertTrue(target.playWhenReady)
        assertEquals(Player.REPEAT_MODE_ALL, target.repeatMode)
        assertTrue(target.shuffleModeEnabled)
        assertTrue(target.calls.indexOf("setPlayWhenReady") < target.calls.indexOf("setMediaItems"))
        assertTrue("prepare" in target.calls)
    }

    @Test
    fun keepsMidBookPositionPendingUntilReceiverReportsProgress() {
        val item = mediaItem("book")
        val handoff = PlaybackHandoff(
            mediaItems = listOf(item),
            currentMediaItemIndex = 0,
            currentPositionMs = 3_600_000L,
            playWhenReady = true,
            repeatMode = Player.REPEAT_MODE_OFF,
            shuffleModeEnabled = false,
            playbackParameters = PlaybackParameters.DEFAULT,
        )
        val target = RecordingPlayer(
            items = listOf(item),
            playWhenReady = true,
            playbackState = Player.STATE_READY,
        )

        assertFalse(handoff.isEstablishedOn(target.player))

        target.currentPositionMs = 1L

        assertFalse(handoff.isEstablishedOn(target.player))

        target.currentPositionMs = 3_600_250L

        assertTrue(handoff.isEstablishedOn(target.player))
    }

    @Test
    fun rejectsReceiverWithOppositePlayIntent() {
        val item = mediaItem("book")
        val handoff = PlaybackHandoff(
            mediaItems = listOf(item),
            currentMediaItemIndex = 0,
            currentPositionMs = 120_000L,
            playWhenReady = true,
            repeatMode = Player.REPEAT_MODE_OFF,
            shuffleModeEnabled = false,
            playbackParameters = PlaybackParameters.DEFAULT,
        )
        val target = RecordingPlayer(
            items = listOf(item),
            currentPositionMs = 120_000L,
            playWhenReady = false,
            playbackState = Player.STATE_READY,
        )

        assertFalse(handoff.isEstablishedOn(target.player))

        target.playWhenReady = true

        assertTrue(handoff.isEstablishedOn(target.player))
    }

    @Test
    fun usesConfirmedReceiverStateInsteadOfOptimisticallyMaskedPlayerState() {
        val item = mediaItem("book")
        val handoff = PlaybackHandoff(
            mediaItems = listOf(item),
            currentMediaItemIndex = 0,
            currentPositionMs = 120_000L,
            playWhenReady = true,
            repeatMode = Player.REPEAT_MODE_OFF,
            shuffleModeEnabled = false,
            playbackParameters = PlaybackParameters.DEFAULT,
        )
        val target = RecordingPlayer(
            items = listOf(item),
            currentPositionMs = 120_000L,
            playWhenReady = true,
            playbackState = Player.STATE_READY,
        )

        assertFalse(
            handoff.isEstablishedOn(
                player = target.player,
                confirmedPositionMs = 0L,
                confirmedPlayWhenReady = false,
            ),
        )
        assertTrue(
            handoff.isEstablishedOn(
                player = target.player,
                confirmedPositionMs = 120_000L,
                confirmedPlayWhenReady = true,
            ),
        )
    }

    @Test
    fun rejectsReceiverThatDroppedPendingQueueAddition() {
        val first = mediaItem("first")
        val second = mediaItem("second")
        val handoff = PlaybackHandoff(
            mediaItems = listOf(first, second),
            currentMediaItemIndex = 0,
            currentPositionMs = 120_000L,
            playWhenReady = false,
            repeatMode = Player.REPEAT_MODE_OFF,
            shuffleModeEnabled = false,
            playbackParameters = PlaybackParameters.DEFAULT,
        )
        val target = RecordingPlayer(
            items = listOf(first),
            currentPositionMs = 120_000L,
            playbackState = Player.STATE_READY,
        )

        assertTrue(handoff.hasExpectedCurrentItemOn(target.player))
        assertFalse(handoff.isEstablishedOn(target.player))
    }

    @Test
    fun rejectsStaleReceiverItemAtMatchingPosition() {
        val handoff = PlaybackHandoff(
            mediaItems = listOf(mediaItem("expected")),
            currentMediaItemIndex = 0,
            currentPositionMs = 120_000L,
            playWhenReady = false,
            repeatMode = Player.REPEAT_MODE_OFF,
            shuffleModeEnabled = false,
            playbackParameters = PlaybackParameters.DEFAULT,
        )
        val target = RecordingPlayer(
            items = listOf(mediaItem("stale")),
            currentPositionMs = 120_000L,
            playbackState = Player.STATE_READY,
        )

        assertFalse(handoff.isEstablishedOn(target.player))
    }

    @Test
    fun emptyHandoffClearsTargetWithoutPreparing() {
        val target = RecordingPlayer(items = listOf(mediaItem("stale")))

        PlaybackHandoff(
            mediaItems = emptyList(),
            currentMediaItemIndex = 0,
            currentPositionMs = 0L,
            playWhenReady = false,
            repeatMode = Player.REPEAT_MODE_OFF,
            shuffleModeEnabled = false,
            playbackParameters = PlaybackParameters.DEFAULT,
        ).applyTo(target.player)

        assertTrue(target.items.isEmpty())
        assertFalse("prepare" in target.calls)
    }

    private fun mediaItem(id: String): MediaItem =
        MediaItem.Builder().setMediaId(id).build()

    private class RecordingPlayer(
        var items: List<MediaItem> = emptyList(),
        var currentIndex: Int = 0,
        var currentPositionMs: Long = 0L,
        var playWhenReady: Boolean = false,
        var repeatMode: Int = Player.REPEAT_MODE_OFF,
        var shuffleModeEnabled: Boolean = false,
        var playbackParameters: PlaybackParameters = PlaybackParameters.DEFAULT,
        var playbackState: Int = Player.STATE_IDLE,
    ) : InvocationHandler {
        val calls = mutableListOf<String>()
        val player: Player = Proxy.newProxyInstance(
            Player::class.java.classLoader,
            arrayOf(Player::class.java),
            this,
        ) as Player

        override fun invoke(proxy: Any, method: Method, args: Array<out Any?>?): Any? {
            val arguments = args.orEmpty()
            return when (method.name) {
                "getMediaItemCount" -> items.size
                "getMediaItemAt" -> items[arguments[0] as Int]
                "getCurrentMediaItem" -> items.getOrNull(currentIndex)
                "getCurrentMediaItemIndex" -> currentIndex
                "getCurrentPosition", "getContentPosition" -> currentPositionMs
                "getPlayWhenReady" -> playWhenReady
                "getRepeatMode" -> repeatMode
                "getShuffleModeEnabled" -> shuffleModeEnabled
                "getPlaybackParameters" -> playbackParameters
                "getPlaybackState" -> playbackState
                "setPlayWhenReady" -> {
                    calls += method.name
                    playWhenReady = arguments[0] as Boolean
                    null
                }
                "setRepeatMode" -> {
                    calls += method.name
                    repeatMode = arguments[0] as Int
                    null
                }
                "setShuffleModeEnabled" -> {
                    calls += method.name
                    shuffleModeEnabled = arguments[0] as Boolean
                    null
                }
                "setPlaybackParameters" -> {
                    calls += method.name
                    playbackParameters = arguments[0] as PlaybackParameters
                    null
                }
                "setMediaItems" -> {
                    calls += method.name
                    @Suppress("UNCHECKED_CAST")
                    items = arguments[0] as List<MediaItem>
                    currentIndex = arguments[1] as Int
                    currentPositionMs = arguments[2] as Long
                    null
                }
                "clearMediaItems" -> {
                    calls += method.name
                    items = emptyList()
                    null
                }
                "prepare" -> {
                    calls += method.name
                    null
                }
                "equals" -> proxy === arguments[0]
                "hashCode" -> System.identityHashCode(proxy)
                "toString" -> "RecordingPlayer"
                else -> defaultValue(method.returnType)
            }
        }

        private fun defaultValue(type: Class<*>): Any? = when (type) {
            java.lang.Boolean.TYPE -> false
            java.lang.Integer.TYPE -> 0
            java.lang.Long.TYPE -> 0L
            java.lang.Float.TYPE -> 0f
            java.lang.Double.TYPE -> 0.0
            else -> null
        }
    }
}
