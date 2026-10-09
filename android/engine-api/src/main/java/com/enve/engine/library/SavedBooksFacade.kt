package com.enve.engine.library

import com.enve.core.data.model.Book
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

@Serializable
enum class SavedBookList(val title: String) {
    FAVORITES("Favorites"),
    LATER("For Later"),
}

interface SavedBooksFacade {
    val saved: StateFlow<Map<SavedBookList, List<String>>>
    val syncErrors: StateFlow<Map<String, String>>
    fun contains(book: Book, list: SavedBookList): Boolean
    suspend fun toggle(book: Book, list: SavedBookList)
    suspend fun refresh()
}
