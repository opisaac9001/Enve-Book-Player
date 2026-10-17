package com.enve.hearth.design

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Velocity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class HearthDismissStateTest {
    private var dismissed = 0
    private val state = HearthDismissState(
        style = HearthDismissStyle.Cover,
        followsFinger = false,
        onDismiss = mutableStateOf({ dismissed++ }),
        scope = CoroutineScope(Dispatchers.Unconfined),
        density = Density(1f),
    )
    private val connection = state.nestedScrollConnection

    @Test
    fun shortDragSpringsBack() {
        state.pullTo(60f)
        state.releaseDrag(velocityY = 100f)
        assertEquals(0, dismissed)
    }

    @Test
    fun longDragOrFastFlingDismisses() {
        state.pullTo(121f)
        state.releaseDrag(velocityY = 0f)
        state.pullTo(31f)
        state.releaseDrag(velocityY = 900f)
        assertEquals(2, dismissed)
    }

    @Test
    fun cancelledDragNeverDismisses() {
        state.pullTo(400f)
        state.releaseDrag(velocityY = null)
        assertEquals(0, dismissed)
    }

    @Test
    fun overscrollAtTopDismissesPastThreshold() = runBlocking {
        state.beginTouch()
        connection.onPostScroll(Offset.Zero, Offset(0f, 85f), NestedScrollSource.UserInput)
        connection.onPreFling(Velocity.Zero)
        assertEquals(1, dismissed)
    }

    @Test
    fun scrollingTowardTopDisarmsTheGesture() = runBlocking {
        state.beginTouch()
        connection.onPostScroll(Offset(0f, 40f), Offset.Zero, NestedScrollSource.UserInput)
        val claimed = connection.onPostScroll(Offset.Zero, Offset(0f, 200f), NestedScrollSource.UserInput)
        assertEquals(Offset.Zero, claimed)
        assertEquals(Velocity.Zero, connection.onPreFling(Velocity(0f, 2_000f)))
        assertEquals(0, dismissed)
    }

    @Test
    fun excludedTouchIsIgnored() = runBlocking {
        state.beginTouch()
        state.touchExcluded = true
        connection.onPostScroll(Offset.Zero, Offset(0f, 200f), NestedScrollSource.UserInput)
        connection.onPreFling(Velocity.Zero)
        assertEquals(0, dismissed)
    }

    @Test
    fun pullingBackUpReturnsDeltaBeforeContentScrolls() = runBlocking {
        state.beginTouch()
        connection.onPostScroll(Offset.Zero, Offset(0f, 90f), NestedScrollSource.UserInput)
        val used = connection.onPreScroll(Offset(0f, -50f), NestedScrollSource.UserInput)
        assertEquals(Offset(0f, -50f), used)
        connection.onPreFling(Velocity.Zero)
        assertEquals(0, dismissed)
    }
}
