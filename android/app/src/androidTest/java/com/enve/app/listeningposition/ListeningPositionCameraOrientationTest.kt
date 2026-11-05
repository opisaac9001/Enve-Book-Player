package com.enve.app.listeningposition

import android.Manifest
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Matrix
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.view.View
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.LiveData
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.NoMatchingViewException
import androidx.test.espresso.matcher.ViewMatchers.withClassName
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.hearth.design.HearthTheme
import com.enve.hearth.listeningposition.ListeningPositionCameraScanner
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin
import org.hamcrest.Matchers.endsWith
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ListeningPositionCameraOrientationTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun rearPreviewIsUprightInPortraitAndLandscapeAndReleasesCamera() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        assumeTrue(context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA))
        InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.CAMERA)
        val manager = context.getSystemService(CameraManager::class.java)
        val rearIds = manager.cameraIdList.filter {
            manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        }.toSet()
        assertTrue("A rear camera is required", rearIds.isNotEmpty())
        val opened = AtomicReference<String?>()
        val available = ConcurrentHashMap<String, Boolean>()
        val callback = object : CameraManager.AvailabilityCallback() {
            override fun onCameraUnavailable(cameraId: String) {
                if (cameraId in rearIds) {
                    available[cameraId] = false
                    opened.set(cameraId)
                }
            }

            override fun onCameraAvailable(cameraId: String) {
                if (cameraId in rearIds) available[cameraId] = true
            }
        }
        manager.registerAvailabilityCallback(callback, Handler(Looper.getMainLooper()))
        try {
            ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
                var originalOrientation = Configuration.ORIENTATION_UNDEFINED
                var originalRotation = Surface.ROTATION_0
                scenario.onActivity {
                    originalOrientation = it.resources.configuration.orientation
                    originalRotation = it.window.decorView.display.rotation
                }
                try {
                    for ((requested, expected) in listOf(
                        ActivityInfo.SCREEN_ORIENTATION_PORTRAIT to Configuration.ORIENTATION_PORTRAIT,
                        ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE to Configuration.ORIENTATION_LANDSCAPE,
                    )) {
                        scenario.onActivity { it.requestedOrientation = requested }
                        compose.waitUntil(10_000) {
                            var orientation = Configuration.ORIENTATION_UNDEFINED
                            scenario.onActivity { orientation = it.resources.configuration.orientation }
                            orientation == expected
                        }
                        compose.waitUntil(10_000) { rearIds.all { available[it] == true } }
                        opened.set(null)
                        val visible = mutableStateOf(true)
                        scenario.onActivity { activity ->
                            activity.setContent {
                                HearthTheme {
                                    if (visible.value) ListeningPositionCameraScanner {}
                                }
                            }
                        }
                        var preview: View? = null
                        var streamState = "NO_VIEW"
                        try {
                            compose.waitUntil(15_000) {
                                try {
                                    onView(withClassName(endsWith(".PreviewView"))).check { view, _ ->
                                        val state = view.javaClass.getMethod("getPreviewStreamState").invoke(view) as LiveData<*>
                                        streamState = state.value.toString()
                                        if (streamState == "STREAMING") preview = view
                                    }
                                } catch (_: NoMatchingViewException) {
                                }
                                preview != null && opened.get() != null
                            }
                        } catch (failure: Throwable) {
                            throw AssertionError("Preview=$streamState, opened=${opened.get()}, available=$available, orientation=$expected", failure)
                        }
                        val sensor = manager.getCameraCharacteristics(checkNotNull(opened.get()))
                            .get(CameraCharacteristics.SENSOR_ORIENTATION)!!
                        onView(withClassName(endsWith(".PreviewView"))).check { view, _ ->
                            assertTrue(view.width > 0 && view.height > 0)
                            val transform = view.javaClass.getMethod("getSensorToViewTransform").invoke(view) as Matrix?
                            assertNotNull("A streaming preview must have its sensor transform", transform)
                            val displayDegrees = when (view.display.rotation) {
                                Surface.ROTATION_90 -> 90
                                Surface.ROTATION_180 -> 180
                                Surface.ROTATION_270 -> 270
                                else -> 0
                            }
                            val angle = Math.toRadians(((sensor - displayDegrees + 360) % 360).toDouble())
                            val axes = floatArrayOf(1f, 0f, 0f, 1f)
                            transform!!.mapVectors(axes)
                            val xLength = hypot(axes[0].toDouble(), axes[1].toDouble())
                            val yLength = hypot(axes[2].toDouble(), axes[3].toDouble())
                            assertEquals(cos(angle), axes[0] / xLength, 0.02)
                            assertEquals(sin(angle), axes[1] / xLength, 0.02)
                            assertEquals(-sin(angle), axes[2] / yLength, 0.02)
                            assertEquals(cos(angle), axes[3] / yLength, 0.02)
                            val bitmap = view.javaClass.getMethod("getBitmap").invoke(view) as android.graphics.Bitmap?
                            assertNotNull("A streaming preview must render a frame", bitmap)
                            bitmap!!.recycle()
                        }
                        compose.runOnIdle { visible.value = false }
                        compose.waitUntil(10_000) { rearIds.all { available[it] == true } }
                    }
                } finally {
                    val requested = when (originalRotation) {
                        Surface.ROTATION_90 -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                        Surface.ROTATION_180 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
                        Surface.ROTATION_270 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                        else -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                    }
                    scenario.onActivity { it.requestedOrientation = requested }
                    compose.waitUntil(10_000) {
                        var restored = false
                        scenario.onActivity {
                            restored = it.resources.configuration.orientation == originalOrientation &&
                                it.window.decorView.display.rotation == originalRotation
                        }
                        restored
                    }
                }
            }
        } finally {
            manager.unregisterAvailabilityCallback(callback)
        }
    }
}
