package com.enve.app.viewmodel

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.data.reader.CustomFont
import com.enve.app.data.repository.CustomFontRepository
import com.enve.core.data.local.PreferencesManager
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class CustomFontsViewModel @Inject constructor(
    private val repository: CustomFontRepository,
    private val preferences: PreferencesManager,
) : ViewModel() {

    val fonts: StateFlow<List<CustomFont>> = repository.observeFonts()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000L), emptyList())

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    fun consumeError() { _error.value = null }

    fun addVariant(
        familyId: String?,
        displayName: String,
        variant: CustomFontRepository.Variant,
        sourceUri: Uri,
    ) {
        viewModelScope.launch {
            repository.addVariant(familyId, displayName, variant, sourceUri)
                .onFailure { _error.value = it.message ?: "Couldn't add font" }
        }
    }

    fun rename(id: String, newName: String) {
        viewModelScope.launch {
            val existing = repository.listFonts().firstOrNull { it.id == id }
            val selectedName = preferences.readerCustomFontName.first()
            val result = repository.rename(id, newName)
            result.exceptionOrNull()?.let {
                _error.value = it.message ?: "Couldn't rename font"
                return@launch
            }
            if (existing != null && selectedName == existing.displayName) {
                preferences.saveReaderPreferences(customFontName = newName.trim())
            }
        }
    }

    fun deleteFamily(id: String) {
        viewModelScope.launch {
            val existing = repository.listFonts().firstOrNull { it.id == id }
            val selectedName = preferences.readerCustomFontName.first()
            val result = repository.deleteFamily(id)
            result.exceptionOrNull()?.let {
                _error.value = it.message ?: "Couldn't delete font"
                return@launch
            }
            if (existing != null && selectedName == existing.displayName) {
                preferences.saveReaderPreferences(customFontName = "")
            }
        }
    }

    fun deleteVariant(id: String, variant: CustomFontRepository.Variant) {
        viewModelScope.launch {
            val existing = repository.listFonts().firstOrNull { it.id == id }
            val selectedName = preferences.readerCustomFontName.first()
            val result = repository.deleteVariant(id, variant)
            result.exceptionOrNull()?.let {
                _error.value = it.message ?: "Couldn't delete variant"
                return@launch
            }
            if (result.getOrNull() == null && existing != null && selectedName == existing.displayName) {
                preferences.saveReaderPreferences(customFontName = "")
            }
        }
    }

}
