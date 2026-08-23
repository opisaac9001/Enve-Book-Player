package com.enve.app.eink

import android.content.Context
import android.content.Intent
import android.view.View
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

enum class EpdRefreshMode {
    PARTIAL,
    FULL,
}

@Singleton
class EpdRefreshManager @Inject constructor(
    @ApplicationContext private val context: Context,
    private val einkManager: EinkManager,
) {
    fun requestPartialRefresh(view: View) {
        requestRefresh(view, EpdRefreshMode.PARTIAL)
    }

    fun requestFullRefresh(view: View) {
        requestRefresh(view, EpdRefreshMode.FULL)
    }

    fun requestTransitionRefresh(view: View) {
        val strength = einkManager.refreshStrength.value
        when (strength) {
            0 -> return
            1, 2 -> requestPartialRefresh(view)
            else -> requestFullRefresh(view)
        }
    }

    @Volatile private var turnsSinceFullRefresh: Int = 0

    fun requestPageTurnRefresh(view: View, isFullPageBoundary: Boolean = false) {
        val decision = EpdPageTurnPolicy.decide(
            strength = einkManager.refreshStrength.value,
            fullRefreshEveryN = einkManager.fullRefreshEveryN.value,
            turnsSinceFullRefresh = turnsSinceFullRefresh,
            isFullPageBoundary = isFullPageBoundary,
        )
        turnsSinceFullRefresh = decision.turnsSinceFullRefresh
        when (decision.action) {
            EpdPageTurnAction.NONE -> return
            EpdPageTurnAction.PARTIAL -> requestPartialRefresh(view)
            EpdPageTurnAction.FULL -> requestFullRefresh(view)
        }
    }

    private fun requestRefresh(view: View, mode: EpdRefreshMode) {
        val profile = einkManager.deviceProfile.value
        val active = einkManager.einkActive
        if (!profile.isEink && !active) return

        when (profile.vendor) {
            EinkVendor.BOOX -> requestBooxRefresh(view, mode)
            EinkVendor.HISENSE -> requestHisenseRefresh(mode)
            else -> requestGenericRefresh(view)
        }
    }

    private fun requestBooxRefresh(view: View, mode: EpdRefreshMode): Boolean {
        val modeName = if (mode == EpdRefreshMode.FULL) "GC16" else "A2"
        return runCatching {
            val controller = Class.forName("android.app.EpdController")
            val method = controller.methods.firstOrNull { it.name == "requestEpdMode" }
                ?: return@runCatching false
            method.invoke(
                null,
                view,
                modeName,
                false,
                0,
                0,
                view.width.coerceAtLeast(1),
                view.height.coerceAtLeast(1),
            )
            true
        }.getOrElse {
            requestGenericRefresh(view)
            false
        }
    }

    private fun requestHisenseRefresh(mode: EpdRefreshMode): Boolean {
        return runCatching {
            val intent = Intent("com.hisense.eink.action.SET_EPD_MODE").apply {
                putExtra("mode", if (mode == EpdRefreshMode.FULL) "GC16" else "A2")
            }
            context.sendBroadcast(intent)
            true
        }.getOrDefault(false)
    }

    private fun requestGenericRefresh(view: View): Boolean {
        view.invalidate()
        view.rootView?.invalidate()
        return true
    }
}
