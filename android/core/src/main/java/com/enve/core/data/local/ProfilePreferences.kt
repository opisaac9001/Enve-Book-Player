package com.enve.core.data.local

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import kotlinx.coroutines.CoroutineScope

class ProfilePreferences private constructor(
    val enve: DataStore<Preferences>,
    val hearth: DataStore<Preferences>,
) {
    companion object {
        fun owner(context: Context): ProfilePreferences =
            ProfilePreferences(context.enveDataStore, context.hearthDataStore)

        fun open(
            context: Context,
            locations: ProfileStorageLocations,
            scope: CoroutineScope,
        ): ProfilePreferences {
            if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) return owner(context)
            return ProfilePreferences(
                PreferenceDataStoreFactory.create(scope = scope) { locations.envePreferencesFile },
                PreferenceDataStoreFactory.create(scope = scope) { locations.hearthPreferencesFile },
            )
        }
    }
}
