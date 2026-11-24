package com.enve.app.playback.sleep

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.sqrt

internal class ShakeDetector(
    private val thresholdG: Double = 2.5,
    private val requiredPeaks: Int = 2,
    private val windowMs: Long = 500L,
    private val cooldownMs: Long = 1_000L,
) {
    private val peaks = ArrayDeque<Long>()
    private var lastShakeMs: Long? = null
    private var aboveThreshold = false

    fun onSample(x: Double, y: Double, z: Double, nowMs: Long): Boolean {
        val high = sqrt(x * x + y * y + z * z) > thresholdG
        val rising = high && !aboveThreshold
        aboveThreshold = high
        if (!rising) return false
        peaks.addLast(nowMs)
        while (peaks.isNotEmpty() && nowMs - peaks.first() >= windowMs) peaks.removeFirst()
        if (peaks.size < requiredPeaks) return false
        if (lastShakeMs?.let { nowMs - it < cooldownMs } == true) return false
        lastShakeMs = nowMs
        peaks.clear()
        return true
    }
}

@Singleton
class ShakeDetectionService @Inject constructor(@ApplicationContext context: Context) {
    private val sensorManager = context.getSystemService(SensorManager::class.java)
    private val accelerometer: Sensor? = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)

    val isAvailable: Boolean get() = accelerometer != null

    fun shakes(): Flow<Unit> = callbackFlow {
        val sensor = accelerometer
        val manager = sensorManager
        if (sensor == null || manager == null) {
            close()
            return@callbackFlow
        }
        val detector = ShakeDetector()
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                val (x, y, z) = event.values.map { it / SensorManager.GRAVITY_EARTH.toDouble() }
                if (detector.onSample(x, y, z, SystemClock.elapsedRealtime())) trySend(Unit)
            }

            override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) = Unit
        }
        manager.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_GAME)
        awaitClose { manager.unregisterListener(listener) }
    }
}
