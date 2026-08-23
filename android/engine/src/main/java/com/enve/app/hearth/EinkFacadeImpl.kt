package com.enve.app.hearth

import android.view.View
import com.enve.app.eink.EinkDisplayMode
import com.enve.app.eink.EinkManager
import com.enve.app.eink.EpdRefreshManager
import com.enve.engine.eink.EinkFacade
import com.enve.engine.eink.EinkMode
import com.enve.engine.eink.EinkState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class EinkFacadeImpl @Inject constructor(
    private val einkManager: EinkManager,
    private val epdRefreshManager: EpdRefreshManager,
) : EinkFacade {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override val state: StateFlow<EinkState> =
        combine(
            einkManager.displayMode,
            einkManager.deviceProfile,
            einkManager.boldText,
            einkManager.refreshStrength,
        ) { mode, device, bold, strength ->

            val monochrome = when (mode) {
                EinkDisplayMode.ON -> true
                EinkDisplayMode.AUTO -> device.isEink
                EinkDisplayMode.ON_COLOR, EinkDisplayMode.OFF -> false
            }
            val active = monochrome || mode == EinkDisplayMode.ON_COLOR

            einkManager.setEinkActive(active, monochrome = monochrome)
            EinkState(
                active = active,
                monochrome = monochrome,
                mode = mode.toEinkMode(),
                boldText = bold,
                refreshStrength = strength,
            )
        }.stateIn(scope, SharingStarted.WhileSubscribed(5000), EinkState.Inactive)

    override fun requestFullRefresh(view: View) = epdRefreshManager.requestFullRefresh(view)

    override suspend fun setMode(mode: EinkMode) = einkManager.setDisplayMode(mode.toDisplayMode())
    override suspend fun setRefreshStrength(strength: Int) = einkManager.setRefreshStrength(strength)
    override suspend fun setBoldText(enabled: Boolean) = einkManager.setBoldText(enabled)
}

private fun EinkMode.toDisplayMode(): EinkDisplayMode = when (this) {
    EinkMode.OFF -> EinkDisplayMode.OFF
    EinkMode.AUTO -> EinkDisplayMode.AUTO
    EinkMode.ON -> EinkDisplayMode.ON
    EinkMode.ON_COLOR -> EinkDisplayMode.ON_COLOR
}

private fun EinkDisplayMode.toEinkMode(): EinkMode = when (this) {
    EinkDisplayMode.OFF -> EinkMode.OFF
    EinkDisplayMode.AUTO -> EinkMode.AUTO
    EinkDisplayMode.ON -> EinkMode.ON
    EinkDisplayMode.ON_COLOR -> EinkMode.ON_COLOR
}
