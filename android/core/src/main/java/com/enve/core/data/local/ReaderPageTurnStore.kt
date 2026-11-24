package com.enve.core.data.local

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

enum class ReaderPageTurnStyle { STANDARD, CURL }

class ReaderPageTurnStore(private val dataStore: DataStore<Preferences>) {
    private val styleKey = stringPreferencesKey("reader.pageTurn.style")

    val style: Flow<ReaderPageTurnStyle> = dataStore.data
        .map { preferences -> styleFor(preferences[styleKey]) }
        .distinctUntilChanged()

    suspend fun save(style: ReaderPageTurnStyle) {
        dataStore.edit { it[styleKey] = style.name }
    }

    companion object {
        fun styleFor(stored: String?): ReaderPageTurnStyle =
            ReaderPageTurnStyle.entries.firstOrNull { it.name == stored } ?: ReaderPageTurnStyle.STANDARD
    }
}
