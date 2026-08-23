package com.enve.engine.eink

import android.view.View
import kotlinx.coroutines.flow.StateFlow

interface EinkFacade {
    val state: StateFlow<EinkState>

    fun requestFullRefresh(view: View)

    suspend fun setMode(mode: EinkMode)
    suspend fun setRefreshStrength(strength: Int)
    suspend fun setBoldText(enabled: Boolean)
}
