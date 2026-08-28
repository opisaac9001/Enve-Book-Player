package com.enve.hearth.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.ComicPageLoadingMode
import com.enve.engine.eink.EinkFacade
import com.enve.engine.eink.EinkMode
import com.enve.engine.eink.EinkState
import com.enve.engine.library.LibraryFacade
import com.enve.engine.prefs.PreferencesFacade
import com.enve.engine.prefs.HearthHomeSection
import com.enve.engine.prefs.HearthStartTab
import com.enve.engine.prefs.ReadNextPosition
import com.enve.engine.theme.HearthThemeMode
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class HearthSettingsViewModel @Inject constructor(
    private val prefs: PreferencesFacade,
    private val eink: EinkFacade,
    private val sources: com.enve.engine.sources.SourcesFacade,
    private val library: LibraryFacade,
) : ViewModel() {

    val themeMode = prefs.themeMode.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), HearthThemeMode.SYSTEM)
    val oled = prefs.oledEnabled.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)
    val uiTextScale = prefs.uiTextScale.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 1f)
    val accent = prefs.accentHex.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "#F5921A")
    val skipForward = prefs.skipForwardSeconds.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 30)
    val skipBackward = prefs.skipBackwardSeconds.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 30)
    val defaultSpeed = prefs.defaultSpeed.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 1.0f)
    val einkState: StateFlow<EinkState> = eink.state
    val connections = sources.connections.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val isRefreshing = library.isRefreshing
    val comicPageLoadingMode = prefs.comicPageLoadingMode.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5000),
        ComicPageLoadingMode.STREAM,
    )
    val readNextEnabled = prefs.readNextEnabled.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5000),
        true,
    )
    val readNextPosition = prefs.readNextPosition.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5000),
        ReadNextPosition.BOTTOM,
    )
    val preferredStartTab = prefs.preferredStartTab.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5000),
        HearthStartTab.HEARTH,
    )
    val homeSectionOrder = prefs.homeSectionOrder.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5000),
        HearthHomeSection.entries,
    )

    fun setThemeMode(m: HearthThemeMode) = launch { prefs.setThemeMode(m) }
    fun setOled(v: Boolean) = launch { prefs.setOledEnabled(v) }
    fun setUiTextScale(scale: Float) = launch { prefs.setUiTextScale(scale) }
    fun setAccent(hex: String) = launch { prefs.setAccentHex(hex) }
    fun setSkipForward(s: Int) = launch { prefs.setSkipForwardSeconds(s.coerceIn(5, 120)) }
    fun setSkipBackward(s: Int) = launch { prefs.setSkipBackwardSeconds(s.coerceIn(5, 120)) }
    fun setDefaultSpeed(s: Float) = launch { prefs.setDefaultSpeed(s) }
    fun setEinkMode(m: EinkMode) = launch { eink.setMode(m) }
    fun setEinkStrength(s: Int) = launch { eink.setRefreshStrength(s) }
    fun setEinkBold(v: Boolean) = launch { eink.setBoldText(v) }
    fun syncNow() = launch { library.refresh() }
    fun setComicPageLoadingMode(mode: ComicPageLoadingMode) = launch { prefs.setComicPageLoadingMode(mode) }
    fun setReadNextEnabled(enabled: Boolean) = launch { prefs.setReadNextEnabled(enabled) }
    fun setReadNextPosition(position: ReadNextPosition) = launch { prefs.setReadNextPosition(position) }
    fun setPreferredStartTab(tab: HearthStartTab) = launch { prefs.setPreferredStartTab(tab) }
    fun moveHomeSection(section: HearthHomeSection, offset: Int) = launch {
        val order = homeSectionOrder.value.toMutableList()
        val from = order.indexOf(section)
        val to = from + offset
        if (from >= 0 && to in order.indices) {
            java.util.Collections.swap(order, from, to)
            prefs.setHomeSectionOrder(order)
        }
    }
    fun resetHomeSectionOrder() = launch { prefs.setHomeSectionOrder(HearthHomeSection.entries) }
    fun updateConnection(c: ProviderConnection) = launch { sources.update(c) }
    fun setConnectionEnabled(c: ProviderConnection, enabled: Boolean) = launch { sources.setEnabled(c.id, enabled) }
    fun removeConnection(c: ProviderConnection) = launch { sources.remove(c.id) }

    private inline fun launch(crossinline block: suspend () -> Unit) {
        viewModelScope.launch { block() }
    }
}
