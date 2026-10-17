package com.enve.hearth.design

import android.animation.ValueAnimator
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.spring
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.drag
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.util.addPointerInputChange
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.abs

enum class HearthDismissStyle { Cover, Page }

@Stable
class HearthDismissState internal constructor(
    internal val style: HearthDismissStyle,
    private val followsFinger: Boolean,
    private val onDismiss: State<() -> Unit>,
    private val scope: CoroutineScope,
    density: Density,
) {
    internal var offset by mutableFloatStateOf(0f)
        private set
    internal var touchExcluded = false
    private var touchScrolled = false
    private var pull = 0f
    private var springBack: Job? = null

    private val dragThreshold = with(density) { 120.dp.toPx() }
    private val dragFlingMinimum = with(density) { 30.dp.toPx() }
    private val overscrollThreshold = with(density) { 80.dp.toPx() }
    private val overscrollFlingMinimum = with(density) { 20.dp.toPx() }
    private val flingVelocity = with(density) { 800.dp.toPx() }

    internal fun beginTouch() {
        touchExcluded = false
        touchScrolled = false
    }

    internal fun pullTo(distance: Float) {
        springBack?.cancel()
        pull = distance.coerceAtLeast(0f)
        if (followsFinger) offset = pull
    }

    internal fun releaseDrag(velocityY: Float?) {
        finish(velocityY != null && (pull >= dragThreshold || (velocityY >= flingVelocity && pull > dragFlingMinimum)))
    }

    private fun finish(dismiss: Boolean) {
        pull = 0f
        if (dismiss) {
            onDismiss.value()
        } else if (offset != 0f) {
            springBack = scope.launch {
                animate(offset, 0f, animationSpec = spring(stiffness = Spring.StiffnessMedium)) { value, _ -> offset = value }
            }
        }
    }

    internal val nestedScrollConnection = object : NestedScrollConnection {
        override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
            if (pull <= 0f || available.y >= 0f || source != NestedScrollSource.UserInput) return Offset.Zero
            val used = available.y.coerceAtLeast(-pull)
            pullTo(pull + used)
            return Offset(0f, used)
        }

        override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
            if (source != NestedScrollSource.UserInput) return Offset.Zero
            if (consumed.y != 0f && pull == 0f) touchScrolled = true
            if (touchExcluded || touchScrolled || available.y <= 0f) return Offset.Zero
            pullTo(pull + available.y)
            return Offset(0f, available.y)
        }

        override suspend fun onPreFling(available: Velocity): Velocity {
            if (pull <= 0f) return Velocity.Zero
            finish(pull >= overscrollThreshold || (available.y >= flingVelocity && pull > overscrollFlingMinimum))
            return available
        }
    }
}

@Composable
fun rememberHearthDismissState(style: HearthDismissStyle, onDismiss: () -> Unit): HearthDismissState {
    val followsFinger = !Hearth.reduceMotion && !Hearth.eink.suppressAnimations && ValueAnimator.areAnimatorsEnabled()
    val currentOnDismiss = rememberUpdatedState(onDismiss)
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    return remember(style, followsFinger, scope, density) {
        HearthDismissState(style, followsFinger, currentOnDismiss, scope, density)
    }
}

fun Modifier.hearthDismissGesture(state: HearthDismissState): Modifier = this
    .pointerInput(state) {
        awaitEachGesture {
            awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
            state.beginTouch()
        }
    }
    .then(if (state.style == HearthDismissStyle.Cover) Modifier.pointerInput(state) { detectCoverPull(state) } else Modifier)
    .nestedScroll(state.nestedScrollConnection)
    .graphicsLayer { translationY = state.offset }

fun Modifier.hearthDismissExclusion(state: HearthDismissState): Modifier = pointerInput(state) {
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        state.touchExcluded = true
    }
}

private suspend fun PointerInputScope.detectCoverPull(state: HearthDismissState) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        if (state.touchExcluded) return@awaitEachGesture
        val velocity = VelocityTracker().apply { addPointerInputChange(down) }
        var travel = Offset.Zero
        while (true) {
            val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: return@awaitEachGesture
            if (change.isConsumed || !change.pressed) return@awaitEachGesture
            velocity.addPointerInputChange(change)
            travel += change.positionChange()
            if (travel.getDistance() > viewConfiguration.touchSlop) {
                if (travel.y <= abs(travel.x)) return@awaitEachGesture
                change.consume()
                break
            }
        }
        state.pullTo(travel.y)
        val completed = drag(down.id) { change ->
            velocity.addPointerInputChange(change)
            travel += change.positionChange()
            state.pullTo(travel.y)
            change.consume()
        }
        state.releaseDrag(if (completed) velocity.calculateVelocity().y else null)
    }
}
