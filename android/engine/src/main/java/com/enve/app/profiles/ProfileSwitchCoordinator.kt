package com.enve.app.profiles

import android.content.Context
import android.content.Intent
import android.os.SystemClock
import androidx.room.withTransaction
import com.enve.core.data.local.LinkedBookPair
import com.enve.core.data.local.BookExtras
import com.enve.core.data.local.decodeChapters
import com.enve.core.data.local.encodeChaptersJson
import kotlinx.coroutines.NonCancellable
import com.enve.core.data.local.AdultPinResult
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.FamilyProfile
import com.enve.core.data.local.FamilyProfileRole
import com.enve.core.data.local.FamilyProfileStore
import com.enve.core.data.local.toBook
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.di.ApplicationScope
import com.enve.engine.profiles.ProfileDownloadCandidate
import com.enve.engine.profiles.ProfileDownloadFormat
import com.enve.engine.profiles.ProfilesFacade
import com.enve.engine.profiles.ProfilesUiState
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

data class ActiveProfileRuntime(val generation: Long, val component: ProfileRuntimeComponent) {
    val profileId: String get() = component.resources().locations.profileId
}

@Singleton
class ProfileSwitchCoordinator @Inject constructor(
    @ApplicationContext private val context: Context,
    private val catalog: FamilyProfileStore,
    private val runtimes: ProfileRuntimeRegistry,
    private val lifecycle: ProfileLifecycleRegistry,
    private val deviceAuthentication: ProfileDeviceAuthentication,
    @ApplicationScope private val scope: CoroutineScope,
) : ProfilesFacade {
    private val configuration = context.getSharedPreferences("family_profile_runtime", Context.MODE_PRIVATE)
    private val mutex = Mutex()
    private var generation = 0L
    @Volatile private var authorizedUntil = 0L
    private val mutableRuntime = MutableStateFlow<ActiveProfileRuntime?>(null)
    val activeRuntime: StateFlow<ActiveProfileRuntime?> = mutableRuntime.asStateFlow()
    private val mutableState = MutableStateFlow(
        ProfilesUiState(
            enabled = configuration.getBoolean("enabled", false),
            activeProfileId = configuration.getString("selected", DEFAULT_ADULT_PROFILE_ID),
            profiles = catalog.profiles.value,
        ),
    )
    override val state: StateFlow<ProfilesUiState> = mutableState.asStateFlow()

    init {
        scope.launch {
            catalog.profiles.collect { profiles ->
                mutableState.update { it.copy(profiles = profiles) }
                refreshServerSyncSettings()
            }
        }
    }

    suspend fun initialize() = operation {
        if (mutableRuntime.value != null) return@operation
        refreshServerSyncSettings()
        val selected = if (state.value.enabled) state.value.activeProfileId ?: DEFAULT_ADULT_PROFILE_ID
            else DEFAULT_ADULT_PROFILE_ID
        val profile = profile(selected)
        if (state.value.enabled && childrenExist() && profile.role == FamilyProfileRole.ADULT) {
            mutableState.update { it.copy(activeProfileId = selected, locked = true) }
        } else {
            activate(profile)
        }
    }

    override suspend fun setupOwner(name: String, pin: String?, confirmation: String?, serverSyncEnabled: Boolean?) = operation {
        check(!state.value.enabled) { "Profiles are already enabled." }
        if (!pin.isNullOrEmpty()) {
            require(pin == confirmation) { "The PINs do not match." }
            require(catalog.validPin(pin)) { "Enter a valid parent PIN." }
            deviceAuthentication.requireRecoveryAvailable()
            val result = if (catalog.hasAdultPin) catalog.verifyAdultPin(pin) else catalog.setAdultPin(pin)
            check(result == AdultPinResult.Accepted) { "Confirm the current parent PIN first." }
        }
        catalog.rename(DEFAULT_ADULT_PROFILE_ID, name)
        serverSyncEnabled?.let { runtimes.open(DEFAULT_ADULT_PROFILE_ID).serverSync().setEnabled(it) }
        refreshServerSyncSettings()
        check(configuration.edit().putBoolean("enabled", true).putString("selected", DEFAULT_ADULT_PROFILE_ID).commit())
        mutableState.update { it.copy(enabled = true, activeProfileId = DEFAULT_ADULT_PROFILE_ID, locked = false) }
        grantAuthorization()
        if (mutableRuntime.value == null) activate(profile(DEFAULT_ADULT_PROFILE_ID))
    }

    override suspend fun disableProfiles() = operation {
        requireParent(null)
        check(catalog.profiles.value.size == 1) { "Remove the additional profiles before turning profiles off." }
        if (mutableRuntime.value?.profileId != DEFAULT_ADULT_PROFILE_ID) activate(profile(DEFAULT_ADULT_PROFILE_ID))
        check(configuration.edit().putBoolean("enabled", false).putString("selected", DEFAULT_ADULT_PROFILE_ID).commit())
        revokeAuthorization()
        mutableState.update { it.copy(enabled = false, locked = false) }
    }

    override suspend fun addProfile(name: String, role: FamilyProfileRole, pin: String?, serverSyncEnabled: Boolean): FamilyProfile = operation {
        check(state.value.enabled)
        requireParent(pin)
        val added = if (role == FamilyProfileRole.CHILD) {
            check(catalog.hasAdultPin) { "Set a parent PIN before adding a child." }
            deviceAuthentication.requireRecoveryAvailable()
            catalog.addChild(name)
        } else {
            catalog.addAdult(name)
        }
        runtimes.open(added.id).serverSync().setEnabled(serverSyncEnabled)
        refreshServerSyncSettings()
        added
    }

    override suspend fun renameProfile(profileId: String, name: String, pin: String?) = operation {
        requireParent(pin)
        catalog.rename(profileId, name)
    }

    private fun refreshServerSyncSettings() {
        val settings = catalog.profiles.value.associate { profile ->
            profile.id to com.enve.core.data.local.ProfileServerSyncStore(
                context, com.enve.core.data.local.ProfileStorageLocations.forProfile(context, profile.id),
            ).isEnabled
        }
        mutableState.update { it.copy(serverSyncEnabled = settings) }
    }

    override suspend fun setServerSyncEnabled(profileId: String, enabled: Boolean, pin: String?) = operation {
        requireParent(pin)
        profile(profileId)
        val component = runtimes.open(profileId)
        component.serverSync().setEnabled(false)
        component.database().pendingProgressPushDao().getAll().forEach {
            component.database().pendingProgressPushDao().delete(it.bookId, it.source, it.connectionKey)
        }
        requireParent(null)
        if (enabled) component.serverSync().setEnabled(true)
        refreshServerSyncSettings()
    }

    override suspend fun removeProfile(profileId: String, pin: String?) = operation {
        requireParent(pin)
        require(profileId != DEFAULT_ADULT_PROFILE_ID) { "The owner profile cannot be removed." }
        profile(profileId)
        require(mutableRuntime.value?.profileId != profileId && state.value.activeProfileId != profileId) {
            "Switch to another profile before removing this profile."
        }
        runtimes.block(profileId)
        val component = runtimes.open(profileId)
        component.downloads().pauseAllAndAwait()
        component.comicDownloads().pauseAllAndAwait()
        component.storyAlignJobScheduler().pauseAllAndAwait()
        requireParent(pin)
        catalog.remove(profileId)
        component.audioStorage().listManifests().forEach { component.audioStorage().removeDownload(it.bookId) }
        component.comicStorage().listManifests().forEach { component.comicStorage().removeDownload(it.id) }
        component.resources().vault.clearAll()
        val locations = component.resources().locations
        runtimes.close(profileId)
        withContext(Dispatchers.IO) {
            check(!locations.filesDirectory.exists() || locations.filesDirectory.deleteRecursively())
            check(!locations.cacheDirectory.exists() || locations.cacheDirectory.deleteRecursively())
            val databaseDirectory = checkNotNull(locations.readerDatabaseFile.parentFile)
            check(!databaseDirectory.exists() || databaseDirectory.deleteRecursively())
            PERSONAL_PREFERENCES.forEach { name -> context.deleteSharedPreferences("${name}_profile_$profileId") }
        }
    }

    override suspend fun verifyAdultPin(pin: String): AdultPinResult = operation {
        catalog.verifyAdultPin(pin).also { result ->
            if (result == AdultPinResult.Accepted) {
                grantAuthorization()
                if (state.value.locked) activate(profile(state.value.activeProfileId ?: DEFAULT_ADULT_PROFILE_ID))
                grantAuthorization()
            }
        }
    }

    override suspend fun switchProfile(profileId: String, pin: String?) = operation {
        check(state.value.enabled)
        val destination = profile(profileId)
        if (destination.role == FamilyProfileRole.ADULT && childrenExist()) requireParent(pin)
        activate(destination)
    }

    override suspend fun importCandidates(sourceProfileId: String, pin: String?): List<ProfileDownloadCandidate> = operation {
        requireParent(pin)
        profile(sourceProfileId)
        val source = runtimes.open(sourceProfileId)
        pauseDownloads(source)
        try {
            candidates(sourceProfileId, source).also { requireParent(null) }
        } finally {
            resumeDownloads(source)
        }
    }

    override suspend fun importCompleted(
        sourceProfileId: String,
        targetProfileId: String,
        bookKey: String,
        format: ProfileDownloadFormat,
        pin: String?,
    ): Book = operation {
        requireParent(pin)
        require(sourceProfileId != targetProfileId)
        profile(sourceProfileId)
        profile(targetProfileId)
        val source = runtimes.open(sourceProfileId)
        val target = runtimes.open(targetProfileId)
        pauseDownloads(source)
        pauseDownloads(target)
        try {
            check(candidates(sourceProfileId, source).any { it.bookKey == bookKey && it.format == format }) {
                "This completed download is no longer available."
            }
            requireParent(null)
            val sourceBookId = bookKey.substringAfter(':')
            val existingId = when (format) {
                ProfileDownloadFormat.AUDIOBOOK -> target.audioStorage().importedBookId(sourceProfileId, sourceBookId)
                ProfileDownloadFormat.EBOOK -> target.comicStorage().importedBookId(sourceProfileId, sourceBookId)
            }
            var imported: Book? = null
            var committed = false
            try {
                val book = withContext(Dispatchers.IO) {
                    when (format) {
                        ProfileDownloadFormat.AUDIOBOOK -> {
                            val manifest = target.audioStorage().importCompletedDownload(source.audioStorage(), sourceBookId) {
                                requireParent(null)
                            }
                            Book(
                                id = manifest.bookId,
                                title = manifest.title,
                                author = manifest.author,
                                coverUrl = manifest.coverUrl,
                                duration = manifest.tracks.sumOf { it.durationMs } / 1_000L,
                                source = BookSource.LOCAL,
                                mediaType = AppMediaType.AUDIOBOOK,
                                hasAudio = true,
                                isDownloaded = true,
                            )
                        }
                        ProfileDownloadFormat.EBOOK -> target.comicStorage().importCompletedDownload(source.comicStorage(), sourceBookId) {
                            requireParent(null)
                        }
                    }.also { imported = it }
                }
                val counterpart = importedCounterpart(source, target, sourceProfileId, sourceBookId, book)
                val chapters = if (format == ProfileDownloadFormat.AUDIOBOOK) {
                    val sourceType = source.audioStorage().getManifest(sourceBookId)?.source
                    val sourceBook = source.bookCacheDao().getAudiobooksByIds(listOf(sourceBookId))
                        .map { it.toBook() }
                        .singleOrNull {
                            it.id == sourceBookId && it.mediaType == AppMediaType.AUDIOBOOK && it.source.name == sourceType
                        }
                    sourceBook?.let {
                        source.database().bookExtrasDao().get(it.uniqueKey)?.decodeChapters()
                            ?.takeIf { chapters -> chapters.isNotEmpty() } ?: it.chapters
                    }.orEmpty()
                } else emptyList()
                val database = target.resources().database
                val books = database.bookCacheDao()
                database.withTransaction {
                    requireParent(null)
                    books.insertIfAbsent(book.toCachedBook())
                    if (chapters.isNotEmpty()) {
                        val extras = database.bookExtrasDao()
                        val existing = extras.get(book.uniqueKey)
                        if (existing?.decodeChapters().isNullOrEmpty()) {
                            extras.upsert(
                                BookExtras(
                                    cacheKey = book.uniqueKey,
                                    chaptersJson = encodeChaptersJson(chapters),
                                    audioTracksJson = existing?.audioTracksJson ?: "[]",
                                    updatedAt = System.currentTimeMillis(),
                                ),
                            )
                        }
                    }
                    if (counterpart != null) {
                        val ebook = if (book.mediaType == AppMediaType.EBOOK) book else counterpart
                        val audio = if (book.mediaType == AppMediaType.AUDIOBOOK) book else counterpart
                        val pairs = database.linkedBookPairDao()
                        if (pairs.getForEbook(ebook.uniqueKey) == null && pairs.getForAudiobook(audio.uniqueKey) == null) {
                            requireParent(null)
                            pairs.upsert(LinkedBookPair(ebook.uniqueKey, audio.uniqueKey, updatedAt = System.currentTimeMillis()))
                        }
                    }
                    requireParent(null)
                }
                committed = true
                target.downloads().refreshCompletedDownloads()
                target.comicDownloads().refreshCompletedDownloads()
                books.getByCacheKey(book.uniqueKey)?.toBook() ?: book
            } finally {
                if (!committed && existingId == null) {
                    imported?.let { book ->
                        withContext(NonCancellable + Dispatchers.IO) {
                            when (format) {
                                ProfileDownloadFormat.AUDIOBOOK -> target.audioStorage().removeDownload(book.id)
                                ProfileDownloadFormat.EBOOK -> target.comicStorage().removeDownload(book.id)
                            }
                        }
                    }
                }
            }
        } finally {
            resumeDownloads(source)
            resumeDownloads(target)
        }
    }

    override suspend fun changeAdultPin(currentPin: String?, newPin: String, confirmation: String) = operation {
        requireParent(currentPin)
        require(newPin == confirmation) { "The PINs do not match." }
        require(catalog.validPin(newPin)) { "Enter a valid parent PIN." }
        deviceAuthentication.requireRecoveryAvailable()
        check(catalog.setAdultPin(newPin, currentPin) == AdultPinResult.Accepted) { "The current PIN was not accepted." }
        revokeAuthorization()
    }

    override fun pinRecoveryIntent(): Intent? = deviceAuthentication.recoveryIntent()

    override suspend fun resetAdultPinAfterDeviceAuthentication(newPin: String, confirmation: String) = operation {
        require(newPin == confirmation) { "The PINs do not match." }
        require(catalog.validPin(newPin)) { "Enter a valid parent PIN." }
        deviceAuthentication.verifyRecovery()
        catalog.resetAdultPinAfterDeviceAuthentication(newPin)
        revokeAuthorization()
    }

    override fun onBackground() {
        revokeAuthorization()
        if (state.value.enabled && childrenExist() && profile(state.value.activeProfileId ?: DEFAULT_ADULT_PROFILE_ID).role == FamilyProfileRole.ADULT) {
            mutableState.update { it.copy(locked = true) }
        }
    }

    override fun clearError() {
        mutableState.update { it.copy(error = null) }
    }

    private suspend fun activate(destination: FamilyProfile) {
        if (mutableRuntime.value?.profileId == destination.id && !state.value.locked) return
        mutableState.update { it.copy(switching = true, error = null) }
        val outgoing = mutableRuntime.value
        try {
            val component = runtimes.open(destination.id)
            requireAdultDestination(destination)
            if (outgoing != null && outgoing.profileId != destination.id) {
                runtimes.block(outgoing.profileId)
                outgoing.component.readAloud().stopActiveAndAwait()
                outgoing.component.readAloudCheckpoints().flushPending()
                lifecycle.checkpointAndClose(outgoing.profileId)
                pauseDownloads(outgoing.component)
                val playback = outgoing.component.audioPlayback().state.value
                outgoing.component.sessions().closeLocally(playback.currentPositionMs / 1_000L, playback.durationMs / 1_000L)
                outgoing.component.audioPlayback().stop()
                outgoing.component.audioPlayback().release()
                outgoing.component.httpClient().dispatcher.cancelAll()
                runtimes.close(outgoing.profileId)
            }
            requireAdultDestination(destination)
            check(configuration.edit().putString("selected", destination.id).commit())
            revokeAuthorization()
            runtimes.unblock(destination.id)
            generation += 1
            mutableRuntime.value = ActiveProfileRuntime(generation, component)
            mutableState.update { it.copy(activeProfileId = destination.id, locked = false, switching = false) }
            resumeDownloads(component)
            component.resources().scope.launch { component.pendingProgressReplay().replay() }
        } catch (error: Throwable) {
            mutableState.update { it.copy(switching = false, locked = true) }
            throw error
        }
    }

    private fun requireAdultDestination(destination: FamilyProfile) {
        if (state.value.enabled && childrenExist() && destination.role == FamilyProfileRole.ADULT) requireParent(null)
    }

    private suspend fun pauseDownloads(component: ProfileRuntimeComponent) {
        component.downloads().pauseAllAndAwait()
        component.comicDownloads().pauseAllAndAwait()
        component.storyAlignJobScheduler().pauseAllAndAwait()
    }

    private fun resumeDownloads(component: ProfileRuntimeComponent) {
        if (activeRuntime.value?.component !== component || state.value.locked || state.value.switching) return
        component.downloads().resumeDownloads()
        component.comicDownloads().resumeDownloads()
        component.storyAlignJobScheduler().resume()
    }

    private suspend fun importedCounterpart(
        source: ProfileRuntimeComponent,
        target: ProfileRuntimeComponent,
        sourceProfileId: String,
        sourceBookId: String,
        imported: Book,
    ): Book? {
        val sourceBook = source.bookCacheDao().getBooksForLinking(20_000)
            .map { it.toBook() }
            .filter { it.id == sourceBookId && it.mediaType == imported.mediaType }
            .singleOrNull() ?: return null
        val counterpart = when (imported.mediaType) {
            AppMediaType.EBOOK -> source.bookLinks().linkedAudiobook(sourceBook)
            AppMediaType.AUDIOBOOK -> source.bookLinks().linkedEbook(sourceBook)
            else -> null
        } ?: return null
        val destinationId = when (counterpart.mediaType) {
            AppMediaType.AUDIOBOOK -> target.audioStorage().importedBookId(sourceProfileId, counterpart.id)
            AppMediaType.EBOOK -> target.comicStorage().importedBookId(sourceProfileId, counterpart.id)
            else -> null
        } ?: return null
        return target.bookCacheDao().getByCacheKey(counterpart.copy(id = destinationId, source = BookSource.LOCAL, connectionId = null).uniqueKey)
            ?.toBook()?.takeIf { it.mediaType == counterpart.mediaType && it.source == BookSource.LOCAL }
    }

    private fun candidates(profileId: String, source: ProfileRuntimeComponent): List<ProfileDownloadCandidate> {
        val audio = source.audioStorage().listManifests().filter { source.audioStorage().isDownloaded(it.bookId) }.map {
            ProfileDownloadCandidate(profileId, "AUDIOBOOK:${it.bookId}", it.title, it.author, ProfileDownloadFormat.AUDIOBOOK)
        }
        val ebooks = source.comicStorage().listManifests().filter { source.comicStorage().isDownloaded(it.id) }.map {
            ProfileDownloadCandidate(profileId, "EBOOK:${it.id}", it.title, it.author, ProfileDownloadFormat.EBOOK)
        }
        return (audio + ebooks).sortedBy { it.title.lowercase() }
    }

    private fun profile(id: String): FamilyProfile = checkNotNull(catalog.profiles.value.firstOrNull { it.id == id }) {
        "This profile is no longer available."
    }

    private fun childrenExist(): Boolean = catalog.profiles.value.any { it.role == FamilyProfileRole.CHILD }

    private fun requireParent(pin: String?) {
        if (!childrenExist() && profile(state.value.activeProfileId ?: DEFAULT_ADULT_PROFILE_ID).role == FamilyProfileRole.ADULT) return
        if (authorizedUntil > SystemClock.elapsedRealtime()) return
        val result = pin?.let { catalog.verifyAdultPin(it) }
        check(result == AdultPinResult.Accepted) {
            if (result is AdultPinResult.Locked) "Too many attempts. Try again later." else "Enter the parent PIN."
        }
        grantAuthorization()
    }

    private fun grantAuthorization() {
        val expiry = SystemClock.elapsedRealtime() + 300_000L
        authorizedUntil = expiry
        mutableState.update { it.copy(parentAuthorized = true) }
        scope.launch(Dispatchers.Main.immediate) {
            delay(300_000L)
            if (authorizedUntil == expiry) revokeAuthorization()
        }
    }

    private fun revokeAuthorization() {
        authorizedUntil = 0L
        mutableState.update { it.copy(parentAuthorized = false) }
    }

    private suspend fun <T> operation(block: suspend () -> T): T = scope.async(Dispatchers.Main.immediate) {
        mutex.withLock {
            try {
                block()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                mutableState.update { it.copy(error = error.message?.takeIf { it in USER_MESSAGES } ?: "The profile operation could not be completed. Please try again.") }
                throw error
            }
        }
    }.await()

    private companion object {
        val USER_MESSAGES = setOf(
            "Profiles are already enabled.", "The PINs do not match.", "Enter a valid parent PIN.",
            "Confirm the current parent PIN first.", "Remove the additional profiles before turning profiles off.",
            "Set a parent PIN before adding a child.", "The owner profile cannot be removed.",
            "Switch to another profile before removing this profile.",
            "This completed download is no longer available.", "The current PIN was not accepted.",
            "This profile is no longer available.", "Too many attempts. Try again later.", "Enter the parent PIN.",
        )
        val PERSONAL_PREFERENCES = listOf(
            "hearth_dismissed_shelves", "podcast_subscriptions", "duplicate_groups", "abs_local_listening",
            "abs_cross_provider_history", "bookorbit_history_session_receipts", "grimmory_pending_sessions",
            "komga_progression", "saved_books", "matching_review", "enve_device", "profile_server_sync",
        )
    }
}
