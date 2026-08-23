package com.enve.app.data.sync

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class DeviceIdentity @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val prefs = context.getSharedPreferences("enve_device", Context.MODE_PRIVATE)

    val deviceId: String
        get() {
            prefs.getString(KEY_DEVICE_ID, null)?.let { return it }
            val newId = UUID.randomUUID().toString().replace("-", "").uppercase()
            prefs.edit().putString(KEY_DEVICE_ID, newId).apply()
            return newId
        }

    var deviceName: String
        get() = prefs.getString(KEY_DEVICE_NAME, DEFAULT_NAME) ?: DEFAULT_NAME
        set(value) { prefs.edit().putString(KEY_DEVICE_NAME, value).apply() }

    private companion object {
        const val KEY_DEVICE_ID = "device_id"
        const val KEY_DEVICE_NAME = "device_name"
        const val DEFAULT_NAME = "Enve"
    }
}
