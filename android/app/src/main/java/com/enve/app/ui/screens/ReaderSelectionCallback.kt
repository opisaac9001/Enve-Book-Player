package com.enve.app.ui.screens

internal class ReaderSelectionCallback(
    private val onSelectionStarted: () -> Unit,
    private val onShowPopup: () -> Unit,
    private val onClearSelection: () -> Unit,
) : android.view.ActionMode.Callback {

    @Volatile private var active = false
    val isActive: Boolean get() = active
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val showPopup = Runnable { if (active) onShowPopup() }
    private val clearSelection = Runnable {
        active = false
        onClearSelection()
    }

    fun notifyFingerUp() {
        if (!active) return
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed(showPopup, POPUP_DELAY_MS)
    }

    override fun onCreateActionMode(mode: android.view.ActionMode, menu: android.view.Menu): Boolean {
        handler.removeCallbacksAndMessages(null)
        active = true
        onSelectionStarted()
        menu.clear()
        handler.postDelayed(showPopup, POPUP_DELAY_MS)
        return true
    }

    override fun onPrepareActionMode(mode: android.view.ActionMode, menu: android.view.Menu): Boolean {
        menu.clear()
        if (active) {
            handler.removeCallbacks(showPopup)
            handler.postDelayed(showPopup, POPUP_DELAY_MS)
        }
        return true
    }

    override fun onDestroyActionMode(mode: android.view.ActionMode) {
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed(clearSelection, ACTION_MODE_REBUILD_GRACE_MS)
    }

    override fun onActionItemClicked(mode: android.view.ActionMode, item: android.view.MenuItem): Boolean {
        mode.finish()
        return true
    }

    private companion object {
        const val POPUP_DELAY_MS = 120L
        const val ACTION_MODE_REBUILD_GRACE_MS = 150L
    }
}
