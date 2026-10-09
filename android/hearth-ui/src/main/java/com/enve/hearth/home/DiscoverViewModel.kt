package com.enve.hearth.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.engine.discover.DiscoverFacade
import com.enve.engine.discover.DiscoverSection
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

data class DiscoverState(
    val sections: List<DiscoverSection> = emptyList(),
    val loading: Boolean = true,
    val error: String? = null,
)

@HiltViewModel
class DiscoverViewModel @Inject constructor(private val discover: DiscoverFacade) : ViewModel() {
    private val mutableState = MutableStateFlow(DiscoverState())
    val state: StateFlow<DiscoverState> = mutableState

    init { load() }

    fun load(force: Boolean = false) {
        viewModelScope.launch {
            mutableState.value = mutableState.value.copy(loading = true, error = null)
            try {
                mutableState.value = DiscoverState(sections = discover.load(force))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableState.value = mutableState.value.copy(loading = false, error = e.message ?: "Could not load Discover")
            }
        }
    }
}
