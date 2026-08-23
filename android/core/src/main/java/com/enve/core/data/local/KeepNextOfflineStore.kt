package com.enve.core.data.local

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

data class KeepNextOfflineSettings(
    val enabled: Boolean = false,
    val count: Int = 1,
) {
    companion object {
        val ALLOWED_COUNTS = listOf(1, 2, 3, 5, 10)

        fun normalizeCount(value: Int): Int = value.takeIf { it in ALLOWED_COUNTS } ?: 1
    }
}

@Singleton
class KeepNextOfflineStore @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val dataStore = context.enveDataStore

    val settings: Flow<KeepNextOfflineSettings> = dataStore.data.map { preferences ->
        KeepNextOfflineSettings(
            enabled = preferences[ENABLED] ?: false,
            count = KeepNextOfflineSettings.normalizeCount(preferences[COUNT] ?: 1),
        )
    }

    suspend fun setEnabled(enabled: Boolean) {
        dataStore.edit { it[ENABLED] = enabled }
    }

    suspend fun setCount(count: Int) {
        dataStore.edit { it[COUNT] = KeepNextOfflineSettings.normalizeCount(count) }
    }

    private companion object {
        val ENABLED = booleanPreferencesKey("enve.downloads.keepNextOfflineEnabled")
        val COUNT = intPreferencesKey("enve.downloads.keepNextOfflineCount")
    }
}
