package com.enve.app.eink

data class EinkDeviceProfile(
    val isEink: Boolean,
    val vendor: EinkVendor,
    val hasNativeEpdApi: Boolean,
    val hasAudioOutput: Boolean,
    val hasBluetooth: Boolean,
    val screenWidth: Int,
    val screenHeight: Int,
    val refreshRateHz: Float,
    val manufacturer: String,
    val model: String,
) {
    companion object {
        val Standard = EinkDeviceProfile(
            isEink = false,
            vendor = EinkVendor.NONE,
            hasNativeEpdApi = false,
            hasAudioOutput = true,
            hasBluetooth = false,
            screenWidth = 0,
            screenHeight = 0,
            refreshRateHz = 60f,
            manufacturer = "",
            model = "",
        )
    }
}
