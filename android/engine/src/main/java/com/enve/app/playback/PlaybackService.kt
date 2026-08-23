package com.enve.app.playback

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import androidx.media3.cast.RemoteCastPlayer
import androidx.media3.cast.SessionAvailabilityListener
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceBitmapLoader
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.CacheBitmapLoader
import androidx.media3.session.CommandButton
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionError
import androidx.media3.session.SessionResult
import com.enve.core.data.local.PreferencesManager
import com.enve.engine.playback.PlaybackAutomationContract
import com.enve.engine.impl.R
import com.enve.app.readium.ReadAloudCheckpointRepository
import com.enve.app.readium.ReadAloudPlaybackCoordinator
import com.enve.app.readium.ReadAloudPlaybackRevocation
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import com.enve.core.data.playback.CastBlockedSignal
import com.enve.core.data.playback.CastCompatibility
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import okhttp3.Credentials
import okhttp3.OkHttpClient

@Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
@androidx.annotation.OptIn(UnstableApi::class)
class PlaybackService : MediaLibraryService() {

    private var mediaSession: MediaLibrarySession? = null
    private var audioEffectsManager: AudioEffectsManager? = null
    private var localPlayer: ExoPlayer? = null
    private var castPlayer: RemoteCastPlayer? = null
    private var castContext: CastContext? = null
    private var pendingCastHandoff: PendingCastHandoff? = null
    private var castHandoffJob: Job? = null
    private var chapterStore: PlaybackChapterStore? = null
    private var autoBrowserHelper: AutoMediaBrowserHelper? = null
    private var castStreamResolver: CastStreamResolver? = null
    private var localCastServer: LocalCastServer? = null
    private var progressService: PlayerProgressService? = null
    private var preferences: PreferencesManager? = null
    private var playerSessionService: PlayerSessionService? = null
    private var playbackQueueCoordinator: PlaybackQueueCoordinator? = null
    private var readAloudPlayback: ReadAloudPlaybackCoordinator? = null
    private var readAloudCheckpoints: ReadAloudCheckpointRepository? = null
    private var serviceScope: CoroutineScope? = null
    private var chapterWatchJob: Job? = null
    private var progressWatchJob: Job? = null
    private var wasServicePlaying = false
    private var lastHandledEndedMediaId: String? = null
    private var seekBackMs = 30_000L
    private var seekForwardMs = 30_000L

    private data class PendingCastHandoff(
        var localState: PlaybackHandoff,
        var castMediaItems: List<MediaItem>,
        val localSourcePreserved: Boolean,
        var targetUpdateObserved: Boolean = false,
        var targetSynchronizationIssued: Boolean = false,
        var targetSynchronizationRequired: Boolean = false,
        var positionConfirmationStartedAtElapsedRealtimeMs: Long = SystemClock.elapsedRealtime(),
        var lastReceiverPositionMs: Long? = null,
        var lastReceiverPositionObservedAtElapsedRealtimeMs: Long = 0L,
    )

    private data class CastReceiverMediaItem(
        val contentId: String,
        val contentUrl: String?,
    )

    private data class CastReceiverState(
        val mediaItems: List<CastReceiverMediaItem>,
        val currentMediaItemIndex: Int,
        val positionMs: Long,
        val playWhenReady: Boolean,
    )

    private val allowedControllerPackages = setOf(
        "android",
        "android.media.session.MediaController",
        "com.android.bluetooth",
        "com.android.car.media",
        "com.android.systemui",
        "com.google.android.gms",
        "com.google.android.carassistant",
        "com.google.android.googlequicksearchbox",
        "com.google.android.projection.gearhead",
    )
    private val allowedControllerPackagePrefixes = listOf(
        "com.google.android.apps.automotive",
    )

    @EntryPoint
    @InstallIn(SingletonComponent::class)
    interface PlaybackServiceEntryPoint {
        fun audioEffectsManager(): AudioEffectsManager
        fun okHttpClient(): OkHttpClient
        fun chapterStore(): PlaybackChapterStore
        fun autoBrowserHelper(): AutoMediaBrowserHelper
        fun castStreamResolver(): CastStreamResolver
        fun localCastServer(): LocalCastServer
        fun progressService(): PlayerProgressService
        fun playerSessionService(): PlayerSessionService
        fun playbackQueueCoordinator(): PlaybackQueueCoordinator
        fun readAloudPlayback(): ReadAloudPlaybackCoordinator
        fun readAloudCheckpoints(): ReadAloudCheckpointRepository
        fun preferencesManager(): PreferencesManager
    }

    override fun onCreate() {
        super.onCreate()

        val entryPoint = try {
            EntryPointAccessors.fromApplication(
                applicationContext,
                PlaybackServiceEntryPoint::class.java,
            )
        } catch (e: Exception) {
            Log.w("PlaybackService", "Playback dependencies unavailable", e)
            null
        }

        val dataSourceFactory = entryPoint?.let { entry ->
            val playbackClient = entry.okHttpClient().newBuilder()
                .addInterceptor { chain ->
                    val request = chain.request()
                    val url = request.url
                    if (url.username.isNotBlank() && url.password.isNotBlank()) {
                        chain.proceed(
                            request.newBuilder()
                                .header("Authorization", Credentials.basic(url.username, url.password))
                                .build()
                        )
                    } else {
                        chain.proceed(request)
                    }
                }
                .build()
            val httpFactory = OkHttpDataSource.Factory(playbackClient)
                .setUserAgent("Enve/1.0 (Android; SDK ${android.os.Build.VERSION.SDK_INT})")
            DefaultDataSource.Factory(this, httpFactory)
        }
        val audioAttributes = AudioAttributes.Builder()
            .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
            .setUsage(C.USAGE_MEDIA)
            .build()
        val playerBuilder = ExoPlayer.Builder(this)
            .setSeekBackIncrementMs(30_000)
            .setSeekForwardIncrementMs(30_000)
            .setHandleAudioBecomingNoisy(true)
            .setAudioAttributes(audioAttributes,  true)
        if (dataSourceFactory != null) {
            playerBuilder.setMediaSourceFactory(
                DefaultMediaSourceFactory(this).setDataSourceFactory(dataSourceFactory)
            )
        }

        val exoPlayer = playerBuilder.build()
        exoPlayer.addListener(autoPrepareListener(exoPlayer))
        localPlayer = exoPlayer

        val sharedCastContext = runCatching { CastContext.getSharedInstance(this) }.getOrNull()
        castContext = sharedCastContext
        val cast = sharedCastContext?.let {
            runCatching {
                RemoteCastPlayer.Builder(this)
                    .setMediaItemConverter(EnveMediaItemConverter())
                    .setSeekBackIncrementMs(30_000)
                    .setSeekForwardIncrementMs(30_000)
                    .build()
            }.getOrNull()
        }
        castPlayer = cast

        chapterStore = entryPoint?.chapterStore()
        autoBrowserHelper = entryPoint?.autoBrowserHelper()
        castStreamResolver = entryPoint?.castStreamResolver()
        localCastServer = entryPoint?.localCastServer()
        progressService = entryPoint?.progressService()
        preferences = entryPoint?.preferencesManager()
        playerSessionService = entryPoint?.playerSessionService()
        playbackQueueCoordinator = entryPoint?.playbackQueueCoordinator()
        readAloudPlayback = entryPoint?.readAloudPlayback()
        readAloudCheckpoints = entryPoint?.readAloudCheckpoints()

        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main).also { serviceScope = it }
        val initialPlayer: Player = if (cast != null && cast.isCastSessionAvailable) cast else exoPlayer
        val sessionBuilder = MediaLibrarySession.Builder(
            this,
            NoSkipTrackPlayer(initialPlayer),
            LibraryCallback(scope),
        ).setMediaButtonPreferences(autoMediaButtonPreferences())
        packageManager.getLaunchIntentForPackage(packageName)?.let { launchIntent ->
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            sessionBuilder.setSessionActivity(
                PendingIntent.getActivity(
                    this,
                    0,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }

        if (dataSourceFactory != null) {
            sessionBuilder.setBitmapLoader(
                CacheBitmapLoader(
                    DataSourceBitmapLoader(
                        DataSourceBitmapLoader.DEFAULT_EXECUTOR_SERVICE.get(),
                        dataSourceFactory,
                    )
                )
            )
        }
        mediaSession = sessionBuilder.build()

        setMediaNotificationProvider(
            DefaultMediaNotificationProvider.Builder(this)
                .setChannelName(R.string.playback_notification_channel_name)
                .build()
                .apply { setSmallIcon(R.drawable.ic_notification) }
        )
        setShowNotificationForIdlePlayer(SHOW_NOTIFICATION_FOR_IDLE_PLAYER_NEVER)

        startWatchingChapters()
        startWatchingProgress()
        preferences?.let(::startWatchingSkipIntervals)

        cast?.setSessionAvailabilityListener(object : SessionAvailabilityListener {
            override fun onCastSessionAvailable() {
                serviceScope?.launch {
                    if (isReadAloudQueue()) return@launch
                    if (!beginCastHandoff(cast)) {
                        Log.w(TAG, "Cast handoff failed; local playback remains active")
                    }
                }
            }

            override fun onCastSessionUnavailable() {
                returnPlaybackToLocal()
                localCastServer?.stop()
            }
        })
        cast?.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                confirmCastHandoff(cast)
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (isPlaying) confirmCastHandoff(cast)
            }

            override fun onTimelineChanged(timeline: Timeline, reason: Int) {
                pendingCastHandoff?.targetUpdateObserved = true
                confirmCastHandoff(cast)
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                pendingCastHandoff?.targetUpdateObserved = true
                confirmCastHandoff(cast)
            }

            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int,
            ) {
                confirmCastHandoff(cast)
            }
        })

        audioEffectsManager = entryPoint?.audioEffectsManager()
        audioEffectsManager?.let { effects ->
            exoPlayer.addListener(object : Player.Listener {
                override fun onAudioSessionIdChanged(audioSessionId: Int) {
                    if (audioSessionId > 0) effects.attachToSession(audioSessionId)
                }
            })
            if (exoPlayer.audioSessionId > 0) {
                effects.attachToSession(exoPlayer.audioSessionId)
            }
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? {
        Log.i(
            "PlaybackService",
            "onGetSession pkg=${controllerInfo.packageName} uid=${controllerInfo.uid} trusted=${controllerInfo.isTrusted} sessionPresent=${mediaSession != null}",
        )
        return mediaSession
    }

    override fun onDestroy() {
        progressWatchJob?.cancel()
        progressWatchJob = null
        chapterWatchJob?.cancel()
        chapterWatchJob = null
        restorePendingHandoffForShutdown()
        runCatching {
            runBlocking {
                persistServiceProgress(force = true, handleCompletion = false)
                val player = mediaSession?.player
                if (pendingCastHandoff == null &&
                    player != null &&
                    player.currentMediaItem?.let(::isReadAloudItem) != true
                ) {
                    playerSessionService?.close(
                        positionSec = absolutePositionSec(player),
                        durationSec = absoluteDurationMs(player) / 1000L,
                    )
                }
            }
        }
        serviceScope?.cancel()
        serviceScope = null
        audioEffectsManager?.release()
        castPlayer?.setSessionAvailabilityListener(null)
        localCastServer?.stop()
        localCastServer = null
        castStreamResolver = null
        progressService = null
        playerSessionService = null
        playbackQueueCoordinator = null
        mediaSession?.release()
        mediaSession = null
        localPlayer?.release()
        localPlayer = null
        castPlayer?.release()
        castPlayer = null
        castContext = null
        pendingCastHandoff = null
        super.onDestroy()
    }

    private fun restorePendingHandoffForShutdown() {
        val pending = pendingCastHandoff ?: return
        cancelPendingCastHandoff()
        val session = mediaSession ?: return
        val local = localPlayer ?: return
        clearCastPlayback()
        runCatching {
            pending.localState.copy(playWhenReady = false).applyTo(local)
            if (activePlaybackTarget() !== local) {
                session.setPlayer(NoSkipTrackPlayer(local))
            }
        }.onFailure {
            pendingCastHandoff = pending
            Log.e(TAG, "Unable to preserve pending Cast progress during shutdown", it)
        }
    }

    private suspend fun beginCastHandoff(target: RemoteCastPlayer): Boolean {
        val session = mediaSession ?: return false
        val current = session.player
        if (activePlaybackTarget() === target || current.mediaItemCount == 0) return true

        val captured = PlaybackHandoff.capture(current)
        val targetItems = withContext(Dispatchers.IO) {
            rewriteItemsForCast(captured.mediaItems)
        } ?: run {
            if (activePlaybackTarget() !== castPlayer) localCastServer?.stop()
            CastBlockedSignal.emit(current.currentMediaItem?.mediaMetadata?.albumTitle?.toString())
            return false
        }
        if (!target.isCastSessionAvailable) {
            localCastServer?.stop()
            return true
        }
        if (mediaSession?.player !== current) {
            if (activePlaybackTarget() !== castPlayer) localCastServer?.stop()
            return true
        }
        val latest = PlaybackHandoff.capture(current)
        if (latest.mediaItems != captured.mediaItems) {
            if (activePlaybackTarget() !== castPlayer) localCastServer?.stop()
            return true
        }

        current.playWhenReady = false
        startPendingCastHandoff(
            localState = latest,
            castMediaItems = targetItems,
            localSourcePreserved = true,
        )
        session.setPlayer(NoSkipTrackPlayer(target))
        try {
            latest.copy(mediaItems = targetItems).applyTo(target)
        } catch (e: Exception) {
            Log.e(TAG, "Player handoff failed", e)
            rollbackCastHandoff("receiver load could not be started")
            return false
        }
        confirmCastHandoff(target)
        return true
    }

    private fun returnPlaybackToLocal() {
        if (pendingCastHandoff != null) {
            rollbackCastHandoff("Cast session ended during handoff")
            return
        }
        val session = mediaSession ?: return
        val local = localPlayer ?: return
        val current = session.player
        if (activePlaybackTarget() !== castPlayer) return

        val captured = PlaybackHandoff.capture(current).copy(
            mediaItems = (0 until current.mediaItemCount)
                .map { index -> rewriteForLocal(current.getMediaItemAt(index)) },
        )
        current.playWhenReady = false
        try {
            captured.applyTo(local)
        } catch (e: Exception) {
            Log.e(TAG, "Unable to restore local playback after Cast", e)
            return
        }
        session.setPlayer(NoSkipTrackPlayer(local))
        current.stop()
        current.clearMediaItems()
        wasServicePlaying = local.isPlaying
    }

    private fun rewriteForCast(item: MediaItem): MediaItem? {
        val uri = item.localConfiguration?.uri ?: return item
        if (isReceiverReachableUri(uri)) {

            return if (CastCompatibility.receiverCanValidate(uri.toString())) item else null
        }
        val scheme = uri.scheme?.lowercase()
        if (scheme != "file" && scheme != "content") return null
        val server = localCastServer ?: return null
        if (!server.start()) return null
        val lanUrl = server.urlFor(uri) ?: return null
        val extras = Bundle(item.requestMetadata.extras ?: Bundle.EMPTY).apply {
            putString(CAST_ORIGINAL_URI_EXTRA, uri.toString())
        }
        val requestMeta = item.requestMetadata.buildUpon()
            .setExtras(extras)
            .build()
        return item.buildUpon()
            .setUri(lanUrl)
            .setRequestMetadata(requestMeta)
            .build()
    }

    private fun rewriteForLocal(item: MediaItem): MediaItem {
        val original = item.requestMetadata.extras?.getString(CAST_ORIGINAL_URI_EXTRA)
            ?: item.localConfiguration?.uri
                ?.let { uri -> localCastServer?.sourceUriFor(uri) }
                ?.toString()
            ?: return item
        return item.buildUpon().setUri(original).build()
    }

    private suspend fun rewriteItemsForCast(items: List<MediaItem>): List<MediaItem>? {
        castStreamResolver?.resolve(items)?.let { return it }
        val rewritten = ArrayList<MediaItem>(items.size)
        for (item in items) {
            rewritten += rewriteForCast(item) ?: return null
        }
        return rewritten
    }

    private fun isReceiverReachableUri(uri: Uri): Boolean {
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return false
        val host = uri.host?.lowercase() ?: return false
        return host != "localhost" &&
            host != "0.0.0.0" &&
            host != "::1" &&
            !host.startsWith("127.")
    }

    private suspend fun preparePlaybackTargetForReplacement(
        mediaItems: List<MediaItem>,
        startIndex: Int,
        startPositionMs: Long,
    ): List<MediaItem> {
        if (mediaItems.isEmpty()) {
            withContext(Dispatchers.Main.immediate) {
                cancelPendingCastHandoff()
                clearCastPlayback()
            }
            return mediaItems
        }
        val cast = withContext(Dispatchers.Main.immediate) {
            castPlayer
                ?.takeIf { it.isCastSessionAvailable }
                ?.takeUnless { mediaItems.any(::isReadAloudItem) }
        }
        val castItems = cast?.let {
            withContext(Dispatchers.IO) { rewriteItemsForCast(mediaItems) }
        }
        if (cast != null && castItems == null) {
            CastBlockedSignal.emit(mediaItems.firstOrNull()?.mediaMetadata?.albumTitle?.toString())
        }

        val persistedSpeed = if (mediaItems.any(::isReadAloudItem)) {
            null
        } else {
            preferences?.playbackSpeed?.first()
        }
        return withContext(Dispatchers.Main.immediate) {
            if (cast != null &&
                cast === castPlayer &&
                cast.isCastSessionAvailable &&
                castItems != null
            ) {
                prepareCastReplacement(
                    cast = cast,
                    localItems = mediaItems,
                    castItems = castItems,
                    startIndex = startIndex,
                    startPositionMs = startPositionMs,
                    persistedSpeed = persistedSpeed,
                )
                castItems
            } else {
                if (cast != null && castItems == null) {
                    Log.w(TAG, "Media will remain local because it is not reachable from the Cast receiver")
                }
                prepareLocalReplacement(persistedSpeed)
                localCastServer?.stop()
                mediaItems
            }
        }
    }

    private fun prepareCastReplacement(
        cast: RemoteCastPlayer,
        localItems: List<MediaItem>,
        castItems: List<MediaItem>,
        startIndex: Int,
        startPositionMs: Long,
        persistedSpeed: Float?,
    ) {
        val session = mediaSession ?: return
        val current = session.player
        val playWhenReady = current.playWhenReady
        val localState = PlaybackHandoff(
            mediaItems = localItems,
            currentMediaItemIndex = startIndex.takeUnless { it == C.INDEX_UNSET } ?: 0,
            currentPositionMs = startPositionMs.takeUnless { it == C.TIME_UNSET } ?: 0L,
            playWhenReady = playWhenReady,
            repeatMode = current.repeatMode,
            shuffleModeEnabled = current.shuffleModeEnabled,
            playbackParameters = persistedSpeed?.let(::PlaybackParameters) ?: current.playbackParameters,
        )

        val activeTarget = activePlaybackTarget()
        cancelPendingCastHandoff()
        if (activeTarget !== cast) clearCastPlayback()
        startPendingCastHandoff(
            localState = localState,
            castMediaItems = castItems,
            localSourcePreserved = false,
        )
        cast.playWhenReady = playWhenReady
        cast.repeatMode = localState.repeatMode
        cast.shuffleModeEnabled = localState.shuffleModeEnabled
        cast.playbackParameters = localState.playbackParameters

        if (activeTarget !== cast) {
            current.playWhenReady = false
            session.setPlayer(NoSkipTrackPlayer(cast))
            current.stop()
            current.clearMediaItems()
        }
    }

    private fun prepareLocalReplacement(persistedSpeed: Float?) {
        val session = mediaSession ?: return
        val local = localPlayer ?: return
        val current = session.player
        val playWhenReady = current.playWhenReady
        val repeatMode = current.repeatMode
        val shuffleModeEnabled = current.shuffleModeEnabled
        val playbackParameters = persistedSpeed?.let(::PlaybackParameters) ?: current.playbackParameters

        cancelPendingCastHandoff()
        clearCastPlayback()
        current.playWhenReady = false
        current.stop()
        current.clearMediaItems()
        local.playWhenReady = playWhenReady
        local.repeatMode = repeatMode
        local.shuffleModeEnabled = shuffleModeEnabled
        local.playbackParameters = playbackParameters
        if (activePlaybackTarget() !== local) {
            session.setPlayer(NoSkipTrackPlayer(local))
        }
    }

    private fun startPendingCastHandoff(
        localState: PlaybackHandoff,
        castMediaItems: List<MediaItem>,
        localSourcePreserved: Boolean,
    ) {
        castHandoffJob?.cancel()
        pendingCastHandoff = PendingCastHandoff(
            localState = localState,
            castMediaItems = castMediaItems,
            localSourcePreserved = localSourcePreserved,
        )
        castHandoffJob = serviceScope?.launch {
            repeat(CAST_HANDOFF_TIMEOUT_MS.toInt() / CAST_HANDOFF_POLL_MS.toInt()) {
                delay(CAST_HANDOFF_POLL_MS)
                val cast = castPlayer ?: return@launch
                if (confirmCastHandoff(cast)) return@launch
            }
            rollbackCastHandoff("receiver did not load the requested position")
        }
    }

    private fun cancelPendingCastHandoff() {
        pendingCastHandoff = null
        castHandoffJob?.cancel()
        castHandoffJob = null
    }

    private fun clearCastPlayback() {
        castPlayer?.let { cast ->
            cast.playWhenReady = false
            cast.stop()
            cast.clearMediaItems()
        }
    }

    private fun rollbackCastHandoff(reason: String) {
        val pending = pendingCastHandoff ?: return
        cancelPendingCastHandoff()
        val session = mediaSession ?: return
        val local = localPlayer ?: return
        clearCastPlayback()
        localCastServer?.stop()
        try {
            val localItems = (0 until local.mediaItemCount).map(local::getMediaItemAt)
            if (pending.localSourcePreserved && localItems == pending.localState.mediaItems) {
                local.repeatMode = pending.localState.repeatMode
                local.shuffleModeEnabled = pending.localState.shuffleModeEnabled
                local.playbackParameters = pending.localState.playbackParameters
                local.seekTo(
                    pending.localState.currentMediaItemIndex.coerceIn(
                        0,
                        pending.localState.mediaItems.lastIndex,
                    ),
                    pending.localState.currentPositionMs,
                )
                local.playWhenReady = pending.localState.playWhenReady
            } else {
                pending.localState.applyTo(local)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Unable to restore local playback after failed Cast handoff", e)
            return
        }
        if (activePlaybackTarget() !== local) {
            session.setPlayer(NoSkipTrackPlayer(local))
        }
        wasServicePlaying = local.isPlaying
        Log.w(TAG, "Cast handoff rolled back: $reason")
    }

    private fun synchronizePendingCastState(
        player: Player,
        pending: PendingCastHandoff,
        receiverState: CastReceiverState,
    ) {
        val targetState = pending.localState.copy(mediaItems = pending.castMediaItems)
        if (!targetState.hasExpectedQueueOn(player) ||
            !receiverState.hasExpectedQueue(pending)
        ) {
            targetState.applyTo(player)
            return
        }

        player.repeatMode = targetState.repeatMode
        val targetIndex =
            targetState.currentMediaItemIndex.coerceIn(0, targetState.mediaItems.lastIndex)
        if (receiverState.currentMediaItemIndex != targetIndex ||
            !targetState.isPositionEstablished(receiverState.positionMs)
        ) {
            player.seekTo(targetIndex, targetState.currentPositionMs)
        }
        player.playbackParameters = targetState.playbackParameters
        player.playWhenReady = targetState.playWhenReady
    }

    private fun castReceiverState(): CastReceiverState? {
        val client = castContext
            ?.sessionManager
            ?.currentCastSession
            ?.remoteMediaClient
            ?: return null
        val status = client.mediaStatus ?: return null
        val queueItems = status.queueItems
        val currentMediaItemIndex =
            queueItems.indexOfFirst { item -> item.itemId == status.currentItemId }
        if (currentMediaItemIndex == C.INDEX_UNSET) return null
        val mediaItems = queueItems.map { item ->
            val mediaInfo = item.media ?: return null
            CastReceiverMediaItem(
                contentId = mediaInfo.contentId,
                contentUrl = mediaInfo.contentUrl,
            )
        }
        val playWhenReady = when (status.playerState) {
            MediaStatus.PLAYER_STATE_PLAYING -> true
            MediaStatus.PLAYER_STATE_PAUSED -> false
            else -> return null
        }
        return CastReceiverState(
            mediaItems = mediaItems,
            currentMediaItemIndex = currentMediaItemIndex,
            positionMs = client.approximateStreamPosition.coerceAtLeast(0L),
            playWhenReady = playWhenReady,
        )
    }

    private fun MediaItem.castReceiverIdentity(): CastReceiverMediaItem? {
        val contentUrl = localConfiguration?.uri?.toString() ?: return null
        val contentId = if (mediaId == MediaItem.DEFAULT_MEDIA_ID) {
            contentUrl
        } else {
            mediaId
        }
        return CastReceiverMediaItem(contentId = contentId, contentUrl = contentUrl)
    }

    private fun CastReceiverState.hasExpectedItem(pending: PendingCastHandoff): Boolean {
        if (pending.castMediaItems.isEmpty()) return false
        val expectedIndex = pending.localState.currentMediaItemIndex
            .coerceIn(0, pending.castMediaItems.lastIndex)
        return currentMediaItemIndex == expectedIndex &&
            mediaItems.getOrNull(currentMediaItemIndex) ==
            pending.castMediaItems[expectedIndex].castReceiverIdentity()
    }

    private fun CastReceiverState.hasExpectedQueue(pending: PendingCastHandoff): Boolean {
        val expectedMediaItems = pending.castMediaItems.map { item ->
            item.castReceiverIdentity() ?: return false
        }
        return mediaItems == expectedMediaItems
    }

    private fun updatePendingReceiverPosition(
        player: Player,
        pending: PendingCastHandoff,
        receiverState: CastReceiverState,
    ) {
        if (!pending.localState.hasExpectedCurrentItemOn(player) ||
            !receiverState.hasExpectedItem(pending)
        ) {
            return
        }

        val now = SystemClock.elapsedRealtime()
        val previousPosition = pending.lastReceiverPositionMs
        val referencePosition = previousPosition ?: pending.localState.currentPositionMs
        val referenceTime = if (previousPosition == null) {
            pending.positionConfirmationStartedAtElapsedRealtimeMs
        } else {
            pending.lastReceiverPositionObservedAtElapsedRealtimeMs
        }
        val elapsedMs = (now - referenceTime).coerceAtLeast(0L)
        val playbackRate = if (pending.localState.playWhenReady) {
            pending.localState.playbackParameters.speed.coerceAtLeast(1f)
        } else {
            0f
        }
        val maximumPosition = referencePosition +
            (elapsedMs * playbackRate).toLong() +
            CAST_RECEIVER_FORWARD_TOLERANCE_MS
        val minimumPosition =
            (referencePosition - CAST_RECEIVER_BACKWARD_TOLERANCE_MS).coerceAtLeast(0L)
        if (receiverState.positionMs !in minimumPosition..maximumPosition) return

        pending.localState = pending.localState.copy(
            currentMediaItemIndex = player.currentMediaItemIndex,
            currentPositionMs = receiverState.positionMs,
        )
        pending.lastReceiverPositionMs = receiverState.positionMs
        pending.lastReceiverPositionObservedAtElapsedRealtimeMs = now
    }

    private fun confirmCastHandoff(player: Player): Boolean {
        val pending = pendingCastHandoff ?: return false
        if (!pending.targetUpdateObserved) {
            return false
        }
        val receiverState = castReceiverState() ?: return false
        val receiverHasExpectedItem = receiverState.hasExpectedItem(pending)
        if (receiverHasExpectedItem) {
            updatePendingReceiverPosition(player, pending, receiverState)
        }
        if (pending.targetSynchronizationRequired) {
            if (pending.targetSynchronizationIssued) {
                return false
            }
            pending.targetSynchronizationIssued = true
            pending.targetSynchronizationRequired = false
            try {
                synchronizePendingCastState(player, pending, receiverState)
            } catch (e: Exception) {
                Log.e(TAG, "Unable to synchronize pending Cast state", e)
                rollbackCastHandoff("receiver state could not be synchronized")
            }
            return false
        }
        if (!receiverHasExpectedItem) {
            return false
        }
        if (!receiverState.hasExpectedQueue(pending) ||
            !pending.localState.isEstablishedOn(
                player = player,
                confirmedPositionMs = receiverState.positionMs,
                confirmedPlayWhenReady = receiverState.playWhenReady,
            )
        ) {
            if (pending.targetSynchronizationIssued ||
                !pending.localState.hasExpectedCurrentItemOn(player)
            ) {
                return false
            }
            pending.targetSynchronizationIssued = true
            try {
                synchronizePendingCastState(player, pending, receiverState)
            } catch (e: Exception) {
                Log.e(TAG, "Unable to synchronize pending Cast state", e)
                rollbackCastHandoff("receiver state could not be synchronized")
            }
            return false
        }
        val cast = castPlayer ?: return false
        localPlayer?.let { local ->
            if (activePlaybackTarget() !== local) {
                local.stop()
                local.clearMediaItems()
            }
        }
        cast.repeatMode = pending.localState.repeatMode
        cast.shuffleModeEnabled = pending.localState.shuffleModeEnabled
        cast.playbackParameters = pending.localState.playbackParameters
        cancelPendingCastHandoff()
        wasServicePlaying = cast.isPlaying
        Log.i(TAG, "Cast handoff established")
        return true
    }

    private fun activePlaybackTarget(): Player? =
        (mediaSession?.player as? NoSkipTrackPlayer)?.underlying ?: mediaSession?.player

    private fun beginNormalPlaybackRequest(
        mediaItems: List<MediaItem>,
        emptyIsNormalPlayback: Boolean = false,
    ): ReadAloudPlaybackRevocation? {
        if (mediaItems.isEmpty() && !emptyIsNormalPlayback) return null
        if (mediaItems.isNotEmpty() && mediaItems.all(::isReadAloudItem)) return null
        val revocation = readAloudPlayback?.revokeForNormalPlayback() ?: return null
        if (revocation.activeSessionId != null && isReadAloudQueue()) {
            mediaSession?.player?.pause()
        }
        return revocation
    }

    private suspend fun finishNormalPlaybackRequest(revocation: ReadAloudPlaybackRevocation?) {
        if (revocation == null) return
        readAloudPlayback?.completeNormalPlaybackRevocation(
            revocation = revocation,
            stopActivePlayer = false,
        )
        readAloudCheckpoints?.flushPending()
    }

    private fun isReadAloudQueue(): Boolean {
        val player = mediaSession?.player ?: return false
        return (0 until player.mediaItemCount).any { index ->
            isReadAloudItem(player.getMediaItemAt(index))
        }
    }

    private fun isReadAloudItem(item: MediaItem): Boolean =
        item.mediaId.startsWith(ReadAloudPlaybackCoordinator.MEDIA_ID_PREFIX)

    companion object {
        private const val TAG = "PlaybackService"
        private const val CAST_HANDOFF_POLL_MS = 250L
        private const val CAST_HANDOFF_TIMEOUT_MS = 20_000L
        private const val CAST_RECEIVER_FORWARD_TOLERANCE_MS = 5_000L
        private const val CAST_RECEIVER_BACKWARD_TOLERANCE_MS = 2_000L
        private val NEXT_CHAPTER_COMMAND = SessionCommand(
            PlaybackAutomationContract.COMMAND_NEXT_CHAPTER,
            Bundle.EMPTY,
        )
        private val PREVIOUS_CHAPTER_COMMAND = SessionCommand(
            PlaybackAutomationContract.COMMAND_PREVIOUS_CHAPTER,
            Bundle.EMPTY,
        )
        private val SEEK_TO_COMMAND = SessionCommand(
            PlaybackAutomationContract.COMMAND_SEEK_TO,
            Bundle.EMPTY,
        )
        private val SEEK_BY_COMMAND = SessionCommand(
            PlaybackAutomationContract.COMMAND_SEEK_BY,
            Bundle.EMPTY,
        )
    }

    private fun autoPrepareListener(exoPlayer: ExoPlayer): Player.Listener =
        object : Player.Listener {
            override fun onTimelineChanged(timeline: Timeline, reason: Int) {
                if (!timeline.isEmpty &&
                    exoPlayer.playbackState == Player.STATE_IDLE &&
                    activePlaybackTarget() === exoPlayer
                ) {
                    exoPlayer.prepare()
                }
            }
        }

    private fun autoMediaButtonPreferences(): ImmutableList<CommandButton> {
        val buttons = mutableListOf(
            CommandButton.Builder(skipBackIcon(seekBackMs))
                .setDisplayName("Back ${seekBackMs / 1000} seconds")
                .setPlayerCommand(Player.COMMAND_SEEK_BACK)
                .setSlots(CommandButton.SLOT_BACK_SECONDARY, CommandButton.SLOT_BACK)
                .build(),
            CommandButton.Builder(skipForwardIcon(seekForwardMs))
                .setDisplayName("Forward ${seekForwardMs / 1000} seconds")
                .setPlayerCommand(Player.COMMAND_SEEK_FORWARD)
                .setSlots(CommandButton.SLOT_FORWARD_SECONDARY, CommandButton.SLOT_FORWARD)
                .build(),
        )
        if (chapterStore?.snapshot?.value?.chapters?.isNotEmpty() == true) {
            buttons += CommandButton.Builder(CommandButton.ICON_NEXT)
                .setDisplayName("Next chapter")
                .setSessionCommand(NEXT_CHAPTER_COMMAND)
                .setSlots(CommandButton.SLOT_FORWARD_SECONDARY, CommandButton.SLOT_OVERFLOW)
                .build()
        }
        return ImmutableList.copyOf(buttons)
    }

    private fun startWatchingSkipIntervals(preferences: PreferencesManager) {
        val scope = serviceScope ?: return
        scope.launch {
            preferences.skipBackwardSeconds.collectLatest { seconds ->
                seekBackMs = seconds.coerceIn(5, 120) * 1000L
                mediaSession?.setMediaButtonPreferences(autoMediaButtonPreferences())
            }
        }
        scope.launch {
            preferences.skipForwardSeconds.collectLatest { seconds ->
                seekForwardMs = seconds.coerceIn(5, 120) * 1000L
                mediaSession?.setMediaButtonPreferences(autoMediaButtonPreferences())
            }
        }
    }

    private fun skipBackIcon(incrementMs: Long): Int = when (incrementMs / 1000L) {
        5L -> CommandButton.ICON_SKIP_BACK_5
        10L -> CommandButton.ICON_SKIP_BACK_10
        15L -> CommandButton.ICON_SKIP_BACK_15
        30L -> CommandButton.ICON_SKIP_BACK_30
        else -> CommandButton.ICON_SKIP_BACK
    }

    private fun skipForwardIcon(incrementMs: Long): Int = when (incrementMs / 1000L) {
        5L -> CommandButton.ICON_SKIP_FORWARD_5
        10L -> CommandButton.ICON_SKIP_FORWARD_10
        15L -> CommandButton.ICON_SKIP_FORWARD_15
        30L -> CommandButton.ICON_SKIP_FORWARD_30
        else -> CommandButton.ICON_SKIP_FORWARD
    }

    private fun startWatchingChapters() {
        val store = chapterStore ?: return
        val scope = serviceScope ?: return
        chapterWatchJob?.cancel()
        chapterWatchJob = scope.launch {
            store.snapshot.collectLatest { snapshot ->
                mediaSession?.setMediaButtonPreferences(autoMediaButtonPreferences())
                if (snapshot.chapters.isEmpty()) return@collectLatest
                applyChapterMetadata(snapshot)
                coroutineScope {
                    while (isActive) {
                        delay(1000)
                        applyChapterMetadata(snapshot)
                    }
                }
            }
        }
    }

    private fun startWatchingProgress() {
        val scope = serviceScope ?: return
        if (progressService == null) return
        progressWatchJob?.cancel()
        progressWatchJob = scope.launch {
            while (isActive) {
                persistServiceProgress(force = false)
                delay(1_000)
            }
        }
    }

    private suspend fun persistServiceProgress(force: Boolean, handleCompletion: Boolean = true) {
        if (pendingCastHandoff != null && activePlaybackTarget() === castPlayer) return
        val service = progressService ?: return
        val player = mediaSession?.player ?: return
        val mediaItem = player.currentMediaItem ?: return
        if (isReadAloudItem(mediaItem)) return
        val isPlaying = player.isPlaying
        val ended = player.playbackState == Player.STATE_ENDED
        val justStopped = wasServicePlaying && !isPlaying
        wasServicePlaying = isPlaying
        val mediaId = mediaItem.mediaId.takeIf { it.isNotBlank() }
        val positionMs = absolutePositionMs(player)
        val durationMs = absoluteDurationMs(player)

        playerSessionService?.markPlaybackChanged(
            isPlaying = isPlaying,
            positionSec = positionMs / 1000L,
            durationSec = durationMs / 1000L,
        )
        if (!ended) lastHandledEndedMediaId = null
        if (!force && !isPlaying && !justStopped && !ended) return

        val persisted = service.persistPlayback(
            mediaId = mediaId,
            bookId = null,
            positionMs = positionMs,
            durationMs = durationMs,
            force = force || justStopped || ended,
        )
        if ((force || justStopped || ended) && persisted != null) {
            service.syncImmediate(
                book = persisted.book,
                currentTimeSec = persisted.currentTimeSec,
                progressFraction = persisted.progressFraction,
            )
        }
        if (ended && handleCompletion && mediaId != lastHandledEndedMediaId) {
            lastHandledEndedMediaId = mediaId
            playerSessionService?.close(
                positionSec = positionMs / 1000L,
                durationSec = durationMs / 1000L,
            )
            playbackQueueCoordinator?.onPlaybackCompleted(mediaId)
        }
    }

    private fun applyChapterMetadata(snapshot: PlaybackChapterStore.Snapshot) {

        if (activePlaybackTarget() === castPlayer) return
        val session = mediaSession ?: return
        val player = session.player
        val current = player.currentMediaItem ?: return
        val currentCacheKey = AutoMediaBrowserHelper.cacheKeyFrom(current.mediaId) ?: return
        if (snapshot.cacheKey != currentCacheKey) return

        val chapter = snapshot.chapters.getOrNull(snapshot.chapterIndexAt(absolutePositionSec(player))) ?: return
        val chapterTitle = chapter.title
        val existingMeta = current.mediaMetadata
        if (existingMeta.title?.toString() == chapterTitle) return

        val bookTitle = snapshot.title.orEmpty()
        val authorLine = listOfNotNull(
            snapshot.author?.takeIf { it.isNotBlank() },
            bookTitle.takeIf { it.isNotBlank() },
        ).joinToString(" - ").ifBlank { snapshot.author }
        val updated = existingMeta.buildUpon()
            .setTitle(chapterTitle)
            .setSubtitle(bookTitle.ifBlank { null })
            .setArtist(authorLine)
            .setAlbumTitle(bookTitle.ifBlank { null })
            .setDescription(chapterTitle)
            .build()

        player.replaceMediaItem(
            player.currentMediaItemIndex,
            current.buildUpon().setMediaMetadata(updated).build(),
        )
    }

    private fun absolutePositionSec(player: Player): Long = absolutePositionMs(player) / 1000L

    private fun absolutePositionMs(player: Player): Long {
        val offsetMs = (0 until player.currentMediaItemIndex).sumOf { index ->
            player.getMediaItemAt(index).mediaMetadata.durationMs ?: 0L
        }
        return (offsetMs + player.currentPosition).coerceAtLeast(0L)
    }

    private fun absoluteDurationMs(player: Player): Long {
        val itemDurations = (0 until player.mediaItemCount).sumOf { index ->
            player.getMediaItemAt(index).mediaMetadata.durationMs ?: 0L
        }
        return itemDurations.takeIf { it > 0L } ?: player.duration.coerceAtLeast(0L)
    }

    private fun hasLibraryAccess(controllerInfo: MediaSession.ControllerInfo): Boolean {
        if (controllerInfo.isTrusted) return true
        if (controllerInfo.uid == applicationInfo.uid) return true
        val controllerPackage = controllerInfo.packageName
        if (controllerPackage == packageName) return true
        return controllerPackage in allowedControllerPackages ||
            allowedControllerPackagePrefixes.any { controllerPackage.startsWith(it) }
    }

    private data class Resolved(
        val items: List<MediaItem>,
        val startIndex: Int,
        val startPositionMs: Long,
    )

    private inner class LibraryCallback(
        private val scope: CoroutineScope,
    ) : MediaLibrarySession.Callback {

        override fun onConnect(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
        ): MediaSession.ConnectionResult {
            val libraryAccess = hasLibraryAccess(controller)
            Log.i(
                "PlaybackService",
                "onConnect pkg=${controller.packageName} uid=${controller.uid} trusted=${controller.isTrusted} libraryAccess=$libraryAccess",
            )
            val sessionCommands = if (libraryAccess) {
                MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS
                    .buildUpon()
                    .add(NEXT_CHAPTER_COMMAND)
                    .add(PREVIOUS_CHAPTER_COMMAND)
                    .add(SEEK_TO_COMMAND)
                    .add(SEEK_BY_COMMAND)
                    .build()
            } else {
                MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS
            }
            val resultBuilder = MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                .setAvailableSessionCommands(sessionCommands)
                .setMediaButtonPreferences(autoMediaButtonPreferences())
            if (!libraryAccess) {
                resultBuilder.setAvailablePlayerCommands(
                    session.player.availableCommands.buildUpon()
                        .remove(Player.COMMAND_SET_MEDIA_ITEM)
                        .remove(Player.COMMAND_CHANGE_MEDIA_ITEMS)
                        .remove(Player.COMMAND_SET_PLAYLIST_METADATA)
                        .remove(Player.COMMAND_SET_MEDIA_ITEMS_METADATA)
                        .remove(Player.COMMAND_RELEASE)
                        .build(),
                )
            }
            return resultBuilder.build()
        }

        override fun onCustomCommand(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            customCommand: SessionCommand,
            args: Bundle,
        ): ListenableFuture<SessionResult> {
            val targetMs = when (customCommand) {
                NEXT_CHAPTER_COMMAND -> chapterStore
                    ?.nextChapterStart(absolutePositionSec(session.player))
                    ?.times(1000L)
                PREVIOUS_CHAPTER_COMMAND -> chapterStore
                    ?.previousChapterStart(absolutePositionSec(session.player))
                    ?.times(1000L)
                SEEK_TO_COMMAND -> args
                    .takeIf { it.containsKey(PlaybackAutomationContract.EXTRA_POSITION_MS) }
                    ?.getLong(PlaybackAutomationContract.EXTRA_POSITION_MS)
                    ?.coerceAtLeast(0L)
                SEEK_BY_COMMAND -> args
                    .takeIf { it.containsKey(PlaybackAutomationContract.EXTRA_OFFSET_MS) }
                    ?.getLong(PlaybackAutomationContract.EXTRA_OFFSET_MS)
                    ?.let { offsetMs -> addSeekOffset(absolutePositionMs(session.player), offsetMs) }
                else -> return Futures.immediateFuture(
                    SessionResult(SessionResult.RESULT_ERROR_NOT_SUPPORTED),
                )
            } ?: return Futures.immediateFuture(
                SessionResult(SessionResult.RESULT_ERROR_INVALID_STATE),
            )
            (session.player as? NoSkipTrackPlayer)?.seekToAbsolute(targetMs)
                ?: session.player.seekTo(targetMs)
            return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
        }

        private fun addSeekOffset(positionMs: Long, offsetMs: Long): Long = when {
            offsetMs > 0L && positionMs > Long.MAX_VALUE - offsetMs -> Long.MAX_VALUE
            offsetMs == Long.MIN_VALUE -> 0L
            offsetMs < 0L && positionMs < -offsetMs -> 0L
            else -> (positionMs + offsetMs).coerceAtLeast(0L)
        }

        override fun onGetLibraryRoot(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<MediaItem>> {
            Log.i("PlaybackService", "onGetLibraryRoot pkg=${browser.packageName}")
            val helper = autoBrowserHelper
                ?: return Futures.immediateFuture(LibraryResult.ofError(SessionError.ERROR_NOT_SUPPORTED))
            return Futures.immediateFuture(LibraryResult.ofItem(helper.buildRoot(), params))
        }

        override fun onGetChildren(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            parentId: String,
            page: Int,
            pageSize: Int,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
            Log.i("PlaybackService", "onGetChildren pkg=${browser.packageName} parent=$parentId")
            val helper = autoBrowserHelper
                ?: return Futures.immediateFuture(LibraryResult.ofItemList(ImmutableList.of(), params))
            return launchToListenableFuture {
                val items = helper.getChildren(parentId)
                Log.i("PlaybackService", "onGetChildren parent=$parentId returning ${items.size} items")
                LibraryResult.ofItemList(ImmutableList.copyOf(items), params)
            }
        }

        override fun onSearch(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            query: String,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<Void>> {
            val helper = autoBrowserHelper
                ?: return Futures.immediateFuture(LibraryResult.ofError(SessionError.ERROR_NOT_SUPPORTED))
            return launchToListenableFuture {
                val count = helper.downloadedAudiobookSearchCount(query)
                session.notifySearchResultChanged(browser, query, count, params)
                LibraryResult.ofVoid(params)
            }
        }

        override fun onGetSearchResult(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            query: String,
            page: Int,
            pageSize: Int,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
            val helper = autoBrowserHelper
                ?: return Futures.immediateFuture(LibraryResult.ofItemList(ImmutableList.of(), params))
            return launchToListenableFuture {
                val items = helper.searchDownloadedAudiobooks(query, page, pageSize)
                LibraryResult.ofItemList(ImmutableList.copyOf(items), params)
            }
        }

        override fun onAddMediaItems(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: MutableList<MediaItem>,
        ): ListenableFuture<List<MediaItem>> {
            Log.i("PlaybackService", "onAddMediaItems pkg=${controller.packageName} count=${mediaItems.size}")
            val revocation = beginNormalPlaybackRequest(mediaItems)
            return launchToListenableFuture {
                finishNormalPlaybackRequest(revocation)
                val helper = autoBrowserHelper
                val resolvedItems = if (helper == null) {
                    mediaItems
                } else {
                    resolveQueue(helper, mediaItems).items
                }
                val target = withContext(Dispatchers.Main.immediate) {
                    activePlaybackTarget()
                }
                val targetedItems = if (target === castPlayer) {
                    checkNotNull(withContext(Dispatchers.IO) { rewriteItemsForCast(resolvedItems) }) {
                        "Downloaded media is not reachable from the Cast receiver"
                    }
                } else {
                    resolvedItems
                }
                withContext(Dispatchers.Main.immediate) {
                    check(activePlaybackTarget() === target) {
                        "Playback target changed while media was being resolved"
                    }
                    val pending = pendingCastHandoff
                        ?.takeIf { target === castPlayer }
                    if (pending == null) {
                        targetedItems
                    } else {
                        pending.localState = pending.localState.copy(
                            mediaItems = pending.localState.mediaItems + resolvedItems,
                        )
                        pending.castMediaItems += targetedItems
                        pending.targetSynchronizationIssued = false
                        pending.targetSynchronizationRequired = true
                        castPlayer?.let(::confirmCastHandoff)
                        emptyList()
                    }
                }
            }
        }

        override fun onSetMediaItems(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: MutableList<MediaItem>,
            startIndex: Int,
            startPositionMs: Long,
        ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            Log.i("PlaybackService", "onSetMediaItems pkg=${controller.packageName} count=${mediaItems.size} startIndex=$startIndex startMs=$startPositionMs")
            val revocation = beginNormalPlaybackRequest(mediaItems)
            return launchToListenableFuture {
                finishNormalPlaybackRequest(revocation)
                val helper = autoBrowserHelper
                if (helper == null) {
                    val targetedItems =
                        preparePlaybackTargetForReplacement(mediaItems, startIndex, startPositionMs)
                    return@launchToListenableFuture MediaSession.MediaItemsWithStartPosition(
                        targetedItems,
                        startIndex,
                        startPositionMs,
                    )
                }
                val resolved = resolveQueue(helper, mediaItems)
                val callerSpecifiedPosition = startPositionMs != C.TIME_UNSET && startPositionMs > 0L
                val effectiveIndex = if (callerSpecifiedPosition) {
                    if (resolved.items.isEmpty()) 0 else startIndex.coerceIn(0, resolved.items.lastIndex)
                } else {
                    resolved.startIndex
                }
                val effectiveMs = if (callerSpecifiedPosition) {
                    startPositionMs.coerceAtLeast(0L)
                } else {
                    resolved.startPositionMs
                }
                Log.i("PlaybackService", "onSetMediaItems resolved count=${resolved.items.size} startIndex=$effectiveIndex startMs=$effectiveMs")
                val targetedItems =
                    preparePlaybackTargetForReplacement(resolved.items, effectiveIndex, effectiveMs)
                MediaSession.MediaItemsWithStartPosition(
                    targetedItems,
                    effectiveIndex,
                    effectiveMs,
                )
            }
        }

        override fun onPlaybackResumption(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
        ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            Log.i("PlaybackService", "onPlaybackResumption pkg=${controller.packageName}")
            val revocation = beginNormalPlaybackRequest(emptyList(), emptyIsNormalPlayback = true)
            return launchToListenableFuture {
                finishNormalPlaybackRequest(revocation)
                val helper = autoBrowserHelper
                    ?: throw UnsupportedOperationException("No media browser helper")
                val resolved = helper.resolvePlaybackResumption()
                    ?: throw UnsupportedOperationException("No resumable audiobook")
                val targetedItems = preparePlaybackTargetForReplacement(
                    resolved.items,
                    resolved.startIndex,
                    resolved.startPositionMs,
                )
                MediaSession.MediaItemsWithStartPosition(
                    targetedItems,
                    resolved.startIndex,
                    resolved.startPositionMs,
                )
            }
        }

        private suspend fun resolveQueue(
            helper: AutoMediaBrowserHelper,
            mediaItems: List<MediaItem>,
        ): Resolved {
            val out = mutableListOf<MediaItem>()
            var firstStartIndex = 0
            var firstStartMs = 0L
            var seededFromResolve = false
            mediaItems.forEach { item ->
                if (item.localConfiguration?.uri != null) {
                    out += item
                } else {
                    val resolved = helper.resolveSessionRequest(item)
                    if (resolved != null) {
                        if (!seededFromResolve) {
                            firstStartIndex = out.size + resolved.startIndex
                            firstStartMs = resolved.startPositionMs
                            seededFromResolve = true
                        }
                        out += resolved.items
                    }
                }
            }
            return Resolved(out, firstStartIndex, firstStartMs)
        }

        private fun <T> launchToListenableFuture(block: suspend () -> T): ListenableFuture<T> {
            val future = SettableFuture.create<T>()
            scope.launch(Dispatchers.IO) {
                try {
                    future.set(block())
                } catch (e: CancellationException) {
                    future.cancel(false)
                    throw e
                } catch (t: Throwable) {
                    Log.e("PlaybackService", "library callback failed", t)
                    future.setException(t)
                }
            }
            return future
        }
    }

    private inner class NoSkipTrackPlayer(val underlying: Player) : ForwardingPlayer(underlying) {

        private fun updatePendingCastState(
            positionChanged: Boolean = false,
            update: (PlaybackHandoff) -> PlaybackHandoff,
        ): Boolean {
            if (underlying !== castPlayer) return false
            val pending = pendingCastHandoff ?: return false
            if (!positionChanged) {
                castReceiverState()?.let { receiverState ->
                    updatePendingReceiverPosition(underlying, pending, receiverState)
                }
            }
            pending.localState = update(pending.localState)
            if (positionChanged) {
                pending.positionConfirmationStartedAtElapsedRealtimeMs = SystemClock.elapsedRealtime()
                pending.lastReceiverPositionMs = null
                pending.lastReceiverPositionObservedAtElapsedRealtimeMs = 0L
            }
            pending.targetSynchronizationIssued = false
            pending.targetSynchronizationRequired = true
            confirmCastHandoff(underlying)
            return true
        }

        private fun filtered(source: Player.Commands): Player.Commands =
            source.buildUpon()
                .remove(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
                .remove(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
                .apply {
                    if (source.contains(Player.COMMAND_SEEK_BACK)) {
                        add(Player.COMMAND_SEEK_TO_PREVIOUS)
                    }
                    if (source.contains(Player.COMMAND_SEEK_FORWARD)) {
                        add(Player.COMMAND_SEEK_TO_NEXT)
                    }
                }
                .build()

        override fun getAvailableCommands(): Player.Commands =
            filtered(super.getAvailableCommands())

        override fun isCommandAvailable(command: Int): Boolean = when (command) {
            Player.COMMAND_SEEK_TO_PREVIOUS -> super.isCommandAvailable(Player.COMMAND_SEEK_BACK)
            Player.COMMAND_SEEK_TO_NEXT -> super.isCommandAvailable(Player.COMMAND_SEEK_FORWARD)
            Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
            Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> false
            else -> super.isCommandAvailable(command)
        }

        override fun stop() {
            if (underlying === castPlayer) {
                pendingCastHandoff?.let { pending ->
                    castReceiverState()?.let { receiverState ->
                        updatePendingReceiverPosition(underlying, pending, receiverState)
                    }
                    pending.localState = pending.localState.copy(playWhenReady = false)
                    pending.targetSynchronizationRequired = false
                    pending.targetSynchronizationIssued = true
                }
            }
            super.stop()
        }

        override fun clearMediaItems() {
            if (underlying === castPlayer && pendingCastHandoff != null) {
                cancelPendingCastHandoff()
                localCastServer?.stop()
                localPlayer?.let { local ->
                    local.playWhenReady = false
                    local.stop()
                    local.clearMediaItems()
                }
            }
            super.clearMediaItems()
        }

        override fun play() {
            if (!updatePendingCastState { it.copy(playWhenReady = true) }) {
                super.play()
            }
        }

        override fun pause() {
            if (!updatePendingCastState { it.copy(playWhenReady = false) }) {
                super.pause()
            }
        }

        override fun setPlayWhenReady(playWhenReady: Boolean) {
            if (!updatePendingCastState { it.copy(playWhenReady = playWhenReady) }) {
                super.setPlayWhenReady(playWhenReady)
            }
        }

        override fun setRepeatMode(repeatMode: Int) {
            if (!updatePendingCastState { it.copy(repeatMode = repeatMode) }) {
                super.setRepeatMode(repeatMode)
            }
        }

        override fun setShuffleModeEnabled(shuffleModeEnabled: Boolean) {
            if (!updatePendingCastState { it.copy(shuffleModeEnabled = shuffleModeEnabled) }) {
                super.setShuffleModeEnabled(shuffleModeEnabled)
            }
        }

        override fun setPlaybackParameters(playbackParameters: PlaybackParameters) {
            if (!updatePendingCastState { it.copy(playbackParameters = playbackParameters) }) {
                super.setPlaybackParameters(playbackParameters)
            }
        }

        override fun setPlaybackSpeed(speed: Float) {
            if (!updatePendingCastState {
                    it.copy(
                        playbackParameters = PlaybackParameters(speed, it.playbackParameters.pitch),
                    )
                }
            ) {
                super.setPlaybackSpeed(speed)
            }
        }

        override fun seekTo(positionMs: Long) {
            if (!updatePendingCastState(positionChanged = true, update = {
                    it.copy(
                        currentMediaItemIndex = currentMediaItemIndex,
                        currentPositionMs = positionMs.coerceAtLeast(0L),
                    )
                })
            ) {
                super.seekTo(positionMs)
            }
        }

        override fun seekTo(mediaItemIndex: Int, positionMs: Long) {
            if (!updatePendingCastState(positionChanged = true, update = {
                    it.copy(
                        currentMediaItemIndex = mediaItemIndex,
                        currentPositionMs = positionMs.coerceAtLeast(0L),
                    )
                })
            ) {
                super.seekTo(mediaItemIndex, positionMs)
            }
        }

        override fun seekBack() {
            seekBy(-getSeekBackIncrement())
        }

        override fun seekForward() {
            seekBy(getSeekForwardIncrement())
        }

        override fun seekToPrevious() {
            seekBack()
        }

        override fun seekToNext() {
            seekForward()
        }

        override fun getSeekBackIncrement(): Long = seekBackMs

        override fun getSeekForwardIncrement(): Long = seekForwardMs

        private fun seekBy(deltaMs: Long) {
            if (mediaItemCount <= 1) {
                seekTo(
                    currentMediaItemIndex,
                    (currentPosition + deltaMs).coerceIn(
                        0L,
                        duration.takeIf { it > 0L } ?: Long.MAX_VALUE,
                    ),
                )
                return
            }

            val target = absolutePositionMs()
                .plus(deltaMs)
                .coerceIn(0L, totalDurationMs().takeIf { it > 0L } ?: Long.MAX_VALUE)
            seekToAbsolute(target)
        }

        private fun absolutePositionMs(): Long {
            val offset = (0 until currentMediaItemIndex).sumOf { index ->
                getMediaItemAt(index).mediaMetadata.durationMs ?: 0L
            }
            return (offset + currentPosition).coerceAtLeast(0L)
        }

        private fun totalDurationMs(): Long =
            (0 until mediaItemCount).sumOf { index ->
                getMediaItemAt(index).mediaMetadata.durationMs ?: 0L
            }

        fun seekToAbsolute(positionMs: Long) {
            var running = 0L
            for (index in 0 until mediaItemCount) {
                val duration = getMediaItemAt(index).mediaMetadata.durationMs ?: 0L
                if (duration <= 0L) continue
                if (positionMs < running + duration || index == mediaItemCount - 1) {
                    seekTo(index, (positionMs - running).coerceIn(0L, duration))
                    return
                }
                running += duration
            }
            seekTo(positionMs.coerceAtLeast(0L))
        }
    }
}
