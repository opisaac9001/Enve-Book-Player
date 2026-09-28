package com.enve.core.data.local

import android.content.Context
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SyncedItemAudioTimeStore @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val dataStore = context.enveDataStore

    suspend fun lastSyncedTime(bookId: String): Double? =
        dataStore.data.first()[key(bookId)]

    suspend fun record(bookId: String, currentTime: Double) {
        dataStore.edit { preferences -> preferences[key(bookId)] = currentTime }
    }

    private fun key(bookId: String) =
        doublePreferencesKey("sync.itemAudio.lastSyncedTime.$bookId")
}
