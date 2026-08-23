package com.enve.app.viewmodel

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.PreferencesManager
import com.enve.app.eink.EinkDeviceProfile
import com.enve.app.eink.EinkDisplayMode
import com.enve.app.eink.EinkManager
import com.enve.app.ui.theme.AppTheme
import com.enve.app.ui.theme.EinkProfile
import com.enve.app.ui.theme.EnveColors
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

data class ThemeState(
    val appTheme: AppTheme = AppTheme.DARK,
    val effectiveAppTheme: AppTheme = AppTheme.DARK,
    val themeColor: Color = EnveColors.DefaultAccent,
    val dynamicBackgroundEnabled: Boolean = true,
    val playerBackgroundStyle: String = "albumArt",
    val showSplashLogo: Boolean = true,
    val einkDisplayMode: EinkDisplayMode = EinkDisplayMode.AUTO,
    val einkDeviceProfile: EinkDeviceProfile = EinkDeviceProfile.Standard,
    val einkProfile: EinkProfile = EinkProfile.Inactive,
)

private data class ThemePrefsState(
    val appTheme: AppTheme,
    val themeColor: Color,
    val dynamicBackgroundEnabled: Boolean,
    val playerBackgroundStyle: String,
    val showSplashLogo: Boolean,
)

@HiltViewModel
class ThemeViewModel @Inject constructor(
    private val prefs: PreferencesManager,
    private val einkManager: EinkManager,
) : ViewModel() {

    private val _themeState = MutableStateFlow(ThemeState())
    val themeState: StateFlow<ThemeState> = _themeState.asStateFlow()

    init {
        viewModelScope.launch {
            val themePrefs = combine(
                prefs.themeMode,
                prefs.themeColorHex,
                prefs.dynamicBackgroundEnabled,
                prefs.playerBackgroundStyle,
                prefs.showSplashLogo,
            ) { values: Array<Any?> ->
                ThemePrefsState(
                    appTheme = AppTheme.fromString(values[0] as String),
                    themeColor = parseHexColor(values[1] as String),
                    dynamicBackgroundEnabled = values[2] as Boolean,
                    playerBackgroundStyle = values[3] as String,
                    showSplashLogo = values[4] as Boolean,
                )
            }

            combine(
                themePrefs,
                einkManager.displayMode,
                einkManager.deviceProfile,
                einkManager.boldText,
                einkManager.refreshStrength,
            ) { theme, einkDisplayMode, einkDeviceProfile, boldText, refreshStrength ->
                val shouldUseEinkTheme = when (einkDisplayMode) {
                    EinkDisplayMode.ON -> true
                    EinkDisplayMode.AUTO -> einkDeviceProfile.isEink
                    EinkDisplayMode.ON_COLOR, EinkDisplayMode.OFF -> false
                }
                val einkOptimizationsActive = shouldUseEinkTheme || einkDisplayMode == EinkDisplayMode.ON_COLOR

                val einkProfile = EinkProfile(
                    active = einkOptimizationsActive,
                    monochrome = shouldUseEinkTheme,
                    displayMode = einkDisplayMode,
                    boldText = boldText,
                    refreshStrength = refreshStrength,
                )

                ThemeState(
                    appTheme = theme.appTheme,
                    effectiveAppTheme = if (shouldUseEinkTheme) AppTheme.EINK else theme.appTheme,
                    themeColor = theme.themeColor,
                    dynamicBackgroundEnabled = if (einkOptimizationsActive) false else theme.dynamicBackgroundEnabled,
                    playerBackgroundStyle = theme.playerBackgroundStyle,
                    showSplashLogo = theme.showSplashLogo,
                    einkDisplayMode = einkDisplayMode,
                    einkDeviceProfile = einkDeviceProfile,
                    einkProfile = einkProfile,
                ).also { einkManager.setEinkActive(einkOptimizationsActive, monochrome = shouldUseEinkTheme) }
            }.collect { _themeState.value = it }
        }
    }

    fun setThemeMode(mode: AppTheme) {
        viewModelScope.launch { prefs.setThemeMode(mode.name.lowercase()) }
    }

    fun setThemeColor(color: Color) {
        viewModelScope.launch {
            val hex = String.format("#%08X", color.toArgb())
            prefs.setThemeColorHex(hex)
        }
    }

    fun setDynamicBackgroundEnabled(enabled: Boolean) {
        viewModelScope.launch { prefs.setDynamicBackgroundEnabled(enabled) }
    }

    fun setPlayerBackgroundStyle(style: String) {
        viewModelScope.launch { prefs.setPlayerBackgroundStyle(style) }
    }

    fun setShowSplashLogo(enabled: Boolean) {
        viewModelScope.launch { prefs.setShowSplashLogo(enabled) }
    }

    fun setEinkDisplayMode(mode: EinkDisplayMode) {
        viewModelScope.launch { einkManager.setDisplayMode(mode) }
    }

    val einkRefreshStrength: kotlinx.coroutines.flow.StateFlow<Int> = einkManager.refreshStrength
    val einkBoldText: kotlinx.coroutines.flow.StateFlow<Boolean> = einkManager.boldText
    val einkFullRefreshEveryN: kotlinx.coroutines.flow.StateFlow<Int> = einkManager.fullRefreshEveryN

    fun setEinkRefreshStrength(strength: Int) {
        viewModelScope.launch { einkManager.setRefreshStrength(strength) }
    }

    fun setEinkBoldText(enabled: Boolean) {
        viewModelScope.launch { einkManager.setBoldText(enabled) }
    }

    fun setEinkFullRefreshEveryN(n: Int) {
        viewModelScope.launch { einkManager.setFullRefreshEveryN(n) }
    }

    private fun parseHexColor(hex: String): Color {
        return try {
            Color(android.graphics.Color.parseColor(hex))
        } catch (e: Exception) {
            EnveColors.DefaultAccent
        }
    }
}
