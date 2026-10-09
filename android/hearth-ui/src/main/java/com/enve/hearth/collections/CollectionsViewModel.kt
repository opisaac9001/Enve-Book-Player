package com.enve.hearth.collections

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.CustomSmartCollection
import com.enve.core.data.local.SmartCollectionRuleGroup
import com.enve.core.data.model.Book
import com.enve.engine.collections.CollectionsFacade
import com.enve.engine.library.LibraryFacade
import com.enve.engine.library.SavedBooksFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID
import javax.inject.Inject

@HiltViewModel
class CollectionsViewModel @Inject constructor(
    private val collections: CollectionsFacade,
    library: LibraryFacade,
    savedBooks: SavedBooksFacade,
) : ViewModel() {
    val manual = collections.manualCollections.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val smart = collections.smartCollections.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val books = library.allBooks.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val saved = savedBooks.saved

    private val mutableMembers = MutableStateFlow<List<Book>>(emptyList())
    val members: StateFlow<List<Book>> = mutableMembers
    private val mutableNotice = MutableStateFlow<String?>(null)
    val notice: StateFlow<String?> = mutableNotice

    fun loadManual(id: String) {
        viewModelScope.launch { mutableMembers.value = collections.booksInManualCollection(id) }
    }

    fun loadSmart(collection: CustomSmartCollection) {
        viewModelScope.launch { mutableMembers.value = collections.booksInSmartCollection(collection) }
    }

    fun saveManual(
        id: String?,
        name: String,
        description: String?,
        iconName: String,
        colorHex: String,
        coverUri: String?,
        removeCover: Boolean,
        onSaved: () -> Unit,
    ) {
        mutableNotice.value = null
        viewModelScope.launch {
            try {
                collections.saveManualCollection(id, name, description, iconName, colorHex, coverUri, removeCover)
                mutableNotice.value = if (id == null) "Shelf created" else "Shelf updated"
                onSaved()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableNotice.value = e.message ?: "Could not save shelf"
            }
        }
    }

    fun deleteManual(id: String) {
        viewModelScope.launch {
            collections.deleteManualCollection(id)
            mutableNotice.value = "Shelf deleted"
        }
    }

    fun setMember(id: String, book: Book, included: Boolean) {
        viewModelScope.launch {
            collections.setBookInManualCollection(id, book, included)
            mutableMembers.value = collections.booksInManualCollection(id)
        }
    }

    fun saveSmart(
        existing: CustomSmartCollection?,
        name: String,
        description: String?,
        ruleGroup: SmartCollectionRuleGroup,
        iconName: String,
        colorHex: String,
        coverUri: String?,
        removeCover: Boolean,
        onSaved: () -> Unit,
    ) {
        mutableNotice.value = null
        viewModelScope.launch {
            val now = System.currentTimeMillis()
            val collection = CustomSmartCollection(
                id = existing?.id ?: UUID.randomUUID().toString(),
                name = name,
                description = description,
                mediaType = null,
                status = "ANY",
                length = "ANY",
                addedWithinDays = null,
                query = null,
                rulesJson = Json.encodeToString(ruleGroup),
                iconName = iconName,
                colorHex = colorHex,
                createdAt = existing?.createdAt ?: now,
                updatedAt = now,
            )
            try {
                collections.saveSmartCollection(collection, coverUri, removeCover)
                mutableNotice.value = if (existing == null) "Smart shelf created" else "Smart shelf updated"
                onSaved()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableNotice.value = e.message ?: "Could not save smart shelf"
            }
        }
    }

    fun deleteSmart(id: String) {
        viewModelScope.launch {
            collections.deleteSmartCollection(id)
            mutableNotice.value = "Smart shelf deleted"
        }
    }

    fun clearNotice() {
        mutableNotice.value = null
    }
}
