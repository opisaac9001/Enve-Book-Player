package com.enve.core.data.local

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.enve.core.data.model.VolumeLevelingStrength
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class VolumeLevelingStore(private val dataStore: DataStore<Preferences>) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(context.enveDataStore)

    val strength: Flow<VolumeLevelingStrength> = dataStore.data.map { preferences ->
        VolumeLevelingStrength.fromString(preferences[STRENGTH])
    }

    suspend fun setStrength(strength: VolumeLevelingStrength) {
        dataStore.edit { it[STRENGTH] = strength.name }
    }

    private companion object {
        val STRENGTH = stringPreferencesKey("enve.audio.volumeLevelingStrength")
    }
}
