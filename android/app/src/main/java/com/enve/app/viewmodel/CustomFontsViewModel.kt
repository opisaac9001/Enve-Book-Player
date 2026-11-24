package com.enve.app.viewmodel

import android.graphics.Typeface
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.data.reader.CustomFont
import com.enve.app.data.reader.fonts.ReaderFontCatalog
import com.enve.app.data.reader.fonts.ReaderFontFamily
import com.enve.app.data.reader.fonts.ReaderFontLibrary
import com.enve.app.data.repository.CustomFontRepository
import com.enve.core.data.local.PreferencesManager
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

@HiltViewModel
class CustomFontsViewModel @Inject constructor(
    private val repository: CustomFontRepository,
    private val preferences: PreferencesManager,
    private val library: ReaderFontLibrary,
) : ViewModel() {

    val fonts: StateFlow<List<CustomFont>> = repository.observeFonts()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000L), emptyList())

    val selectedFontName: StateFlow<String> = preferences.readerCustomFontName
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000L), "")

    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()

    val catalog: StateFlow<List<ReaderFontFamily>> = _query
        .map(ReaderFontCatalog::search)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000L), ReaderFontCatalog.families)

    private val _previews = MutableStateFlow<Map<String, Typeface>>(emptyMap())
    val previews: StateFlow<Map<String, Typeface>> = _previews.asStateFlow()

    private val _busy = MutableStateFlow<Set<String>>(emptySet())
    val busy: StateFlow<Set<String>> = _busy.asStateFlow()

    private val _message = MutableStateFlow<String?>(null)
    val message: StateFlow<String?> = _message.asStateFlow()

    fun consumeMessage() { _message.value = null }

    fun showMessage(text: String) { _message.value = text }

    fun search(query: String) {
        _query.value = query.take(ReaderFontCatalog.MAX_QUERY_LENGTH)
    }

    fun preview(family: ReaderFontFamily) {
        if (family.name in _previews.value) return
        runExclusively(family) {
            val file = library.preview(family).getOrElse {
                _message.value = it.message ?: "Couldn't preview ${family.name}"
                return@runExclusively
            }
            val typeface = withContext(Dispatchers.IO) { Typeface.Builder(file).build() }
            if (typeface == null) {
                _message.value = "${family.name} couldn't be previewed"
            } else {
                _previews.update { it + (family.name to typeface) }
            }
        }
    }

    fun install(family: ReaderFontFamily) {
        runExclusively(family) {
            library.install(family)
                .onSuccess { _message.value = "${it.displayName} is ready to use offline" }
                .onFailure { _message.value = it.message ?: "Couldn't download ${family.name}" }
        }
    }

    fun use(font: CustomFont) {
        viewModelScope.launch { preferences.saveReaderPreferences(customFontName = font.displayName) }
    }

    fun addVariant(
        familyId: String?,
        displayName: String,
        variant: CustomFontRepository.Variant,
        sourceUri: Uri,
    ) {
        viewModelScope.launch {
            repository.addVariant(familyId, displayName, variant, sourceUri)
                .onFailure { _message.value = it.message ?: "Couldn't add font" }
        }
    }

    fun rename(id: String, newName: String) {
        viewModelScope.launch {
            val existing = repository.listFonts().firstOrNull { it.id == id }
            val selectedName = preferences.readerCustomFontName.first()
            val result = repository.rename(id, newName)
            result.exceptionOrNull()?.let {
                _message.value = it.message ?: "Couldn't rename font"
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
                _message.value = it.message ?: "Couldn't delete font"
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
                _message.value = it.message ?: "Couldn't delete variant"
                return@launch
            }
            if (result.getOrNull() == null && existing != null && selectedName == existing.displayName) {
                preferences.saveReaderPreferences(customFontName = "")
            }
        }
    }

    private fun runExclusively(family: ReaderFontFamily, block: suspend () -> Unit) {
        if (family.name in _busy.value) return
        _busy.update { it + family.name }
        viewModelScope.launch {
            try {
                block()
            } finally {
                _busy.update { it - family.name }
            }
        }
    }
}
