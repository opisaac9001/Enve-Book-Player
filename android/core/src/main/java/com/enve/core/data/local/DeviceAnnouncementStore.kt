package com.enve.core.data.local

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class DeviceAnnouncementStore(private val store: DataStore<Preferences>) {
    @Inject constructor(@ApplicationContext context: Context) : this(context.applicationContext.enveDataStore)
    private val discordDismissed = booleanPreferencesKey("enve.discordAnnouncementDismissed")
    private val legacyAnnouncementSeen = intPreferencesKey("enve.lastAnnouncementSeen")

    suspend fun shouldShowDiscord(profileLastSeen: Int): Boolean {
        val preferences = store.edit {
            if (profileLastSeen > 0 || (it[legacyAnnouncementSeen] ?: 0) > 0) it[discordDismissed] = true
        }
        return preferences[discordDismissed] != true
    }

    suspend fun dismissDiscord() {
        store.edit { it[discordDismissed] = true }
    }
}
