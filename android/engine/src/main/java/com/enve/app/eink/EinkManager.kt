package com.enve.app.eink

import com.enve.core.data.local.PreferencesManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class EinkManager @Inject constructor(
    private val detector: EinkDetector,
    private val prefs: PreferencesManager,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _deviceProfile = MutableStateFlow(EinkDeviceProfile.Standard)
    val deviceProfile: StateFlow<EinkDeviceProfile> = _deviceProfile.asStateFlow()

    val displayMode: Flow<EinkDisplayMode> = prefs.einkDisplayMode.map(EinkDisplayMode::fromString)

    val refreshStrength: StateFlow<Int> = prefs.einkRefreshStrength
        .stateIn(scope, SharingStarted.Eagerly, 1)

    val boldText: StateFlow<Boolean> = prefs.einkBoldText
        .stateIn(scope, SharingStarted.Eagerly, false)

    val fullRefreshEveryN: StateFlow<Int> = prefs.einkFullRefreshEveryN
        .stateIn(scope, SharingStarted.Eagerly, 6)

    @Volatile
    var einkActive: Boolean = false
        private set

    @Volatile
    var einkMonochrome: Boolean = false
        private set

    fun initialize() {
        _deviceProfile.value = detector.detect()
    }

    fun setEinkActive(active: Boolean, monochrome: Boolean = active) {
        einkActive = active
        einkMonochrome = monochrome
    }

    suspend fun setDisplayMode(mode: EinkDisplayMode) {
        prefs.setEinkDisplayMode(mode.name.lowercase())
    }

    suspend fun setRefreshStrength(strength: Int) {
        prefs.setEinkRefreshStrength(strength)
    }

    suspend fun setBoldText(enabled: Boolean) {
        prefs.setEinkBoldText(enabled)
    }

    suspend fun setFullRefreshEveryN(n: Int) {
        prefs.setEinkFullRefreshEveryN(n)
    }
}
