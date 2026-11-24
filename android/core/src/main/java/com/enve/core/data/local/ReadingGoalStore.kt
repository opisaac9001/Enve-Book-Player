package com.enve.core.data.local

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

data class DailyReadingGoal(
    val enabled: Boolean = false,
    val minutes: Int = DEFAULT_MINUTES,
) {
    val seconds: Long get() = minutes * 60L

    companion object {
        const val MIN_MINUTES = 1
        const val MAX_MINUTES = 240
        const val DEFAULT_MINUTES = 20
    }
}

@Singleton
class ReadingGoalStore(private val dataStore: DataStore<Preferences>) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(context.enveDataStore)

    val goal: Flow<DailyReadingGoal> = dataStore.data
        .map { preferences ->
            DailyReadingGoal(
                enabled = preferences[ENABLED] == true,
                minutes = (preferences[MINUTES] ?: DailyReadingGoal.DEFAULT_MINUTES)
                    .coerceIn(DailyReadingGoal.MIN_MINUTES, DailyReadingGoal.MAX_MINUTES),
            )
        }
        .distinctUntilChanged()

    suspend fun save(minutes: Int) {
        require(minutes in DailyReadingGoal.MIN_MINUTES..DailyReadingGoal.MAX_MINUTES)
        dataStore.edit { preferences ->
            preferences[ENABLED] = true
            preferences[MINUTES] = minutes
        }
    }

    suspend fun disable() {
        dataStore.edit { preferences -> preferences[ENABLED] = false }
    }

    private companion object {
        val ENABLED = booleanPreferencesKey("enve.readingGoal.enabled")
        val MINUTES = intPreferencesKey("enve.readingGoal.dailyMinutes")
    }
}
