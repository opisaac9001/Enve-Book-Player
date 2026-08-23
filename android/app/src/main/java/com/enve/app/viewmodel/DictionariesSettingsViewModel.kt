package com.enve.app.viewmodel

import android.net.Uri
import androidx.lifecycle.ViewModel
import com.enve.app.data.vocab.InstalledDictionariesStore
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

@HiltViewModel
class DictionariesSettingsViewModel @Inject constructor(
    private val store: InstalledDictionariesStore,
) : ViewModel() {

    val dictionaries: StateFlow<List<InstalledDictionariesStore.InstalledDictionary>> = store.dictionaries

    fun installFromFolder(folderUri: Uri): InstalledDictionariesStore.InstalledDictionary =
        store.installFromFolder(folderUri)

    fun delete(slug: String) = store.delete(slug)
}
