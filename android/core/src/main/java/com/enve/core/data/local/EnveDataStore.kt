package com.enve.core.data.local

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.preferencesDataStore

internal val Context.enveDataStore: DataStore<Preferences> by preferencesDataStore(name = "enve_prefs")
