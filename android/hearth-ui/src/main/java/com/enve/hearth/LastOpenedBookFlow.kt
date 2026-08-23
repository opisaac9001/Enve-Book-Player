package com.enve.hearth

import com.enve.core.data.local.LastOpenedBookStore
import com.enve.core.data.model.Book
import com.enve.engine.library.LibraryFacade
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf

@OptIn(ExperimentalCoroutinesApi::class)
internal fun LibraryFacade.observeLastOpenedBook(store: LastOpenedBookStore): Flow<Book?> =
    store.lastOpenedBookKey.flatMapLatest { key ->
        if (key == null) flowOf(null) else bookByKeyFlow(key)
    }
