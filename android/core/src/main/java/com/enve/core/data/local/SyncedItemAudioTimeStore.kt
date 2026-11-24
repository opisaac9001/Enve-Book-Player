package com.enve.core.data.local

import android.content.Context
import com.enve.core.reader.ReaderNarrationKey
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SyncedItemAudioTimeStore(private val dataStore: DataStore<Preferences>) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(context.enveDataStore)

    suspend fun lastSyncedTime(book: ReaderNarrationKey): Double? =
        dataStore.data.first()[key(book)]

    suspend fun record(book: ReaderNarrationKey, currentTime: Double) {
        dataStore.edit { preferences -> preferences[key(book)] = currentTime }
    }

    private fun key(book: ReaderNarrationKey) =
        doublePreferencesKey("sync.itemAudio.scoped.${Json.encodeToString(listOf(book.source.name, book.connectionId, book.bookId))}")
}
