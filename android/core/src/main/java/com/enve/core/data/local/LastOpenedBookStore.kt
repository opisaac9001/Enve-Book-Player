package com.enve.core.data.local

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class LastOpenedBookStore @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val dataStore = context.enveDataStore

    val lastOpenedBookKey: Flow<String?> = dataStore.data
        .map { preferences -> preferences[LAST_OPENED_BOOK_KEY]?.takeIf(String::isNotBlank) }
        .distinctUntilChanged()

    suspend fun record(book: Book) {
        record(book.id, book.source, book.connectionId)
    }

    suspend fun record(bookId: String, source: BookSource, connectionId: String?) {
        val key = "${connectionId ?: source.name}:$bookId"
        dataStore.edit { preferences -> preferences[LAST_OPENED_BOOK_KEY] = key }
    }

    private companion object {
        val LAST_OPENED_BOOK_KEY = stringPreferencesKey("enve.lastOpenedBookKey")
    }
}
