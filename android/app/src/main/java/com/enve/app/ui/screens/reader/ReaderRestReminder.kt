package com.enve.app.ui.screens.reader

import android.os.SystemClock
import android.view.HapticFeedbackConstants
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleStartEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.engine.prefs.PreferencesFacade
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.settings.RestReminderControls
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private const val PROMPT_MS = 60_000L

internal class ReaderRestClock {
    private var accumulatedMs = 0L
    private var resumedAtMs: Long? = null
    private var pausedAtMs: Long? = null

    val isRunning: Boolean get() = resumedAtMs != null

    fun elapsedMs(nowMs: Long): Long = accumulatedMs + (resumedAtMs?.let { nowMs - it } ?: 0L)

    fun resume(nowMs: Long): Boolean {
        if (resumedAtMs != null) return false
        val rested = pausedAtMs?.let { nowMs - it >= RESTING_GAP_MS } ?: false
        if (rested) accumulatedMs = 0L
        pausedAtMs = null
        resumedAtMs = nowMs
        return rested
    }

    fun pause(nowMs: Long) {
        if (resumedAtMs == null) return
        accumulatedMs = elapsedMs(nowMs)
        resumedAtMs = null
        pausedAtMs = nowMs
    }

    fun restart(nowMs: Long) {
        accumulatedMs = 0L
        pausedAtMs = null
        resumedAtMs = nowMs
    }

    companion object {
        const val RESTING_GAP_MS = 5 * 60_000L
    }
}

class ReaderRestReminderSpec(
    val enabled: Boolean,
    val minutes: Int,
    val introShown: Boolean,
    val onIntroShown: () -> Unit,
    val onEnabledChange: (Boolean) -> Unit,
    val onMinutesChange: (Int) -> Unit,
)

@Composable
internal fun rememberReaderRestReminderSpec(preferences: PreferencesFacade): ReaderRestReminderSpec {
    val enabled by preferences.restReminderEnabled.collectAsStateWithLifecycle(initialValue = false)
    val minutes by preferences.restReminderMinutes.collectAsStateWithLifecycle(initialValue = 60)
    val introShown by preferences.restReminderIntroShown.collectAsStateWithLifecycle(initialValue = true)
    val scope = rememberCoroutineScope()
    return ReaderRestReminderSpec(
        enabled = enabled,
        minutes = minutes,
        introShown = introShown,
        onIntroShown = { scope.launch { preferences.setRestReminderIntroShown(true) } },
        onEnabledChange = { scope.launch { preferences.setRestReminderEnabled(it) } },
        onMinutesChange = { scope.launch { preferences.setRestReminderMinutes(it) } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ReaderRestReminder(spec: ReaderRestReminderSpec, modifier: Modifier = Modifier) {
    var showSettings by remember { mutableStateOf(false) }
    if (spec.enabled) {
        RestReminderTimer(spec, onOpenSettings = { showSettings = true }, modifier = modifier)
    }
    if (showSettings) {
        val palette = Hearth.palette
        ModalBottomSheet(onDismissRequest = { showSettings = false }, containerColor = palette.bgElevated) {
            Column(Modifier.padding(horizontal = Hearth.Spacing.XL).navigationBarsPadding().padding(bottom = Hearth.Spacing.XL)) {
                Text("REST YOUR EYES", style = HearthText.Overline, color = palette.textSecondary)
                Text("Reading break reminders", style = HearthText.BookTitle, color = palette.text)
                Spacer(Modifier.height(Hearth.Spacing.M))
                RestReminderControls(
                    enabled = spec.enabled,
                    minutes = spec.minutes,
                    onEnabledChange = spec.onEnabledChange,
                    onMinutesChange = spec.onMinutesChange,
                )
            }
        }
    }
}

@Composable
private fun RestReminderTimer(spec: ReaderRestReminderSpec, onOpenSettings: () -> Unit, modifier: Modifier) {
    val clock = remember { ReaderRestClock().apply { restart(SystemClock.elapsedRealtime()) } }
    var due by remember { mutableStateOf(false) }
    var holding by remember { mutableStateOf(false) }
    var showsSettingsHint by remember { mutableStateOf(false) }
    var foreground by remember { mutableStateOf(true) }
    val introShown by rememberUpdatedState(spec.introShown)
    val onIntroShown by rememberUpdatedState(spec.onIntroShown)

    fun dismiss() {
        clock.restart(SystemClock.elapsedRealtime())
        due = false
        holding = false
    }

    LifecycleStartEffect(clock) {
        if (clock.resume(SystemClock.elapsedRealtime())) {
            due = false
            holding = false
        }
        foreground = true
        onStopOrDispose {
            clock.pause(SystemClock.elapsedRealtime())
            foreground = false
        }
    }

    LaunchedEffect(spec.minutes, due, holding, foreground) {
        if (!foreground || holding) return@LaunchedEffect
        if (due) {
            delay(PROMPT_MS)
            dismiss()
        } else {
            delay((spec.minutes * 60_000L - clock.elapsedMs(SystemClock.elapsedRealtime())).coerceAtLeast(0L))
            clock.pause(SystemClock.elapsedRealtime())
            showsSettingsHint = !introShown
            if (showsSettingsHint) {
                holding = true
                onIntroShown()
            }
            due = true
        }
    }

    ReaderRestPrompt(
        visible = due,
        minutes = spec.minutes,
        showsSettingsHint = showsSettingsHint,
        onOpenSettings = {
            dismiss()
            onOpenSettings()
        },
        onDismiss = ::dismiss,
        modifier = modifier,
    )
}

@Composable
private fun ReaderRestPrompt(
    visible: Boolean,
    minutes: Int,
    showsSettingsHint: Boolean,
    onOpenSettings: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val view = LocalView.current
    LaunchedEffect(visible) {
        if (visible) view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
    }
    val accent = if (eink.active) palette.text else palette.ember

    AnimatedVisibility(
        visible = visible,
        enter = if (eink.suppressAnimations) fadeIn(tween(0)) else fadeIn(tween(220)) + scaleIn(tween(220), initialScale = 0.96f),
        exit = if (eink.suppressAnimations) fadeOut(tween(0)) else fadeOut(tween(180)) + scaleOut(tween(180), targetScale = 0.96f),
        modifier = modifier,
    ) {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = palette.bgElevated,
            shadowElevation = if (eink.active) 0.dp else 12.dp,
            modifier = Modifier
                .widthIn(max = 420.dp)
                .border(1.dp, if (eink.active) palette.text else palette.hairline, RoundedCornerShape(20.dp))
                .semantics { liveRegion = LiveRegionMode.Polite },
        ) {
            Column(Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    Icon(Icons.Outlined.Visibility, contentDescription = null, tint = accent, modifier = Modifier.size(26.dp))
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text("REST YOUR EYES", style = HearthText.Overline, color = palette.textSecondary)
                        Text("Look up for a moment", style = HearthText.BookTitle, color = palette.text)
                        Text(
                            "You've been reading for $minutes minutes. Look at something far away for about 20 seconds.",
                            style = HearthText.Caption,
                            color = palette.textSecondary,
                        )
                    }
                    Spacer(Modifier.width(8.dp))
                    Icon(
                        Icons.Outlined.Close,
                        contentDescription = "Dismiss rest reminder",
                        tint = palette.textSecondary,
                        modifier = Modifier
                            .size(32.dp)
                            .clip(CircleShape)
                            .clickable(onClick = onDismiss)
                            .padding(7.dp),
                    )
                }
                if (showsSettingsHint) {
                    Spacer(Modifier.height(Hearth.Spacing.M))
                    Text(
                        "Turn this reminder off or customize it in Settings.",
                        style = HearthText.Caption,
                        color = palette.textSecondary,
                    )
                    Spacer(Modifier.height(Hearth.Spacing.S))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .border(1.dp, if (eink.active) palette.text else palette.hairline, RoundedCornerShape(50))
                            .clickable(onClick = onOpenSettings)
                            .padding(horizontal = 14.dp, vertical = 9.dp),
                    ) {
                        Icon(Icons.Outlined.Settings, contentDescription = null, tint = palette.text, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Rest reminder settings", style = HearthText.Label, color = palette.text)
                    }
                }
            }
        }
    }
}
