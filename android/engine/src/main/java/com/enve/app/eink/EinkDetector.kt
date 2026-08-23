package com.enve.app.eink

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.display.DisplayManager
import android.os.Build
import android.view.Display
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class EinkDetector @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    fun detect(): EinkDeviceProfile {
        val packageManager = context.packageManager
        val manufacturer = Build.MANUFACTURER.orEmpty()
        val model = Build.MODEL.orEmpty()
        val deviceName = listOf(manufacturer, Build.BRAND, Build.DEVICE, Build.PRODUCT, model)
            .joinToString(" ")
            .uppercase()

        val vendor = EinkDeviceClassifier.detectVendor(deviceName)
        val nativeEpdApi = hasBooxEpdApi() || hasHisenseEpdApi(packageManager)
        val refreshRate = currentRefreshRate()
        val metrics = context.resources.displayMetrics
        val inferredEink = vendor != EinkVendor.NONE || nativeEpdApi || refreshRate in 0.1f..1.5f

        return EinkDeviceProfile(
            isEink = inferredEink,
            vendor = if (vendor != EinkVendor.NONE) vendor else if (inferredEink) EinkVendor.GENERIC_EINK else EinkVendor.NONE,
            hasNativeEpdApi = nativeEpdApi,
            hasAudioOutput = packageManager.hasSystemFeature(PackageManager.FEATURE_AUDIO_OUTPUT),
            hasBluetooth = packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH) ||
                packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE),
            screenWidth = metrics.widthPixels,
            screenHeight = metrics.heightPixels,
            refreshRateHz = refreshRate,
            manufacturer = manufacturer,
            model = model,
        )
    }

    private fun hasBooxEpdApi(): Boolean {
        return runCatching { Class.forName("android.app.EpdController") }.isSuccess ||
            runCatching { Class.forName("com.onyx.android.sdk.api.device.epd.EpdController") }.isSuccess
    }

    private fun hasHisenseEpdApi(packageManager: PackageManager): Boolean {
        return runCatching { packageManager.getPackageInfo("com.hisense.eink", 0) }.isSuccess ||
            runCatching { Class.forName("com.hisense.eink.EPDManager") }.isSuccess
    }

    private fun currentRefreshRate(): Float {
        val displayManager = context.getSystemService(DisplayManager::class.java)
        return displayManager?.getDisplay(Display.DEFAULT_DISPLAY)?.refreshRate ?: 60f
    }
}
