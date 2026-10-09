package com.enve.engine.collections

import com.enve.core.data.local.CustomSmartCollection
import com.enve.core.data.local.UserCollectionSummary
import com.enve.core.data.model.Book
import kotlinx.coroutines.flow.Flow

interface CollectionsFacade {
    val manualCollections: Flow<List<UserCollectionSummary>>
    val smartCollections: Flow<List<CustomSmartCollection>>

    suspend fun saveManualCollection(
        id: String?,
        name: String,
        description: String?,
        iconName: String,
        colorHex: String,
        coverUri: String?,
        removeCover: Boolean,
    ): String

    suspend fun deleteManualCollection(id: String)
    suspend fun booksInManualCollection(id: String): List<Book>
    suspend fun setBookInManualCollection(id: String, book: Book, included: Boolean)

    suspend fun saveSmartCollection(collection: CustomSmartCollection, coverUri: String?, removeCover: Boolean)
    suspend fun deleteSmartCollection(id: String)
    suspend fun booksInSmartCollection(collection: CustomSmartCollection): List<Book>
}
