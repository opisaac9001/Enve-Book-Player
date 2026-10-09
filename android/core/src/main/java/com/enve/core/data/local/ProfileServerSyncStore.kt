package com.enve.core.data.local

import android.content.Context
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReadStatus
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ProfileServerSyncStore @Inject constructor(
    @ApplicationContext context: Context,
    locations: ProfileStorageLocations,
) {
    private val owner = locations.profileId == DEFAULT_ADULT_PROFILE_ID
    private val preferences = context.getSharedPreferences(
        if (owner) "profile_server_sync" else "profile_server_sync_${locations.profileId}", Context.MODE_PRIVATE,
    )
    private val mutableEnabled = MutableStateFlow(preferences.getBoolean("enabled", owner))
    val enabled = mutableEnabled.asStateFlow()
    val isEnabled: Boolean get() = enabled.value
    val enabledSince: Long get() = preferences.getLong("enabled_since", 0L)

    fun accepts(timestamp: Long): Boolean = isEnabled && timestamp >= enabledSince

    suspend fun setEnabled(value: Boolean) = withContext(Dispatchers.IO) {
        if (value == isEnabled) return@withContext
        check(preferences.edit().putBoolean("enabled", value).putLong("enabled_since", System.currentTimeMillis()).commit())
        mutableEnabled.value = value
    }

    fun catalogBook(book: Book): Book = if (isEnabled) book else book.copy(
        currentTime = 0L,
        isFinished = false,
        readStatus = ReadStatus.UNREAD,
        lastReadTime = 0L,
        readProgress = 0f,
        epubProgress = null,
        epubLocator = null,
        hideFromContinue = false,
        serverReadStatus = null,
    )
}
