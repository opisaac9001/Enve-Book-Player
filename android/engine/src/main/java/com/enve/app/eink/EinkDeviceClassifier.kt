package com.enve.app.eink

object EinkDeviceClassifier {
    fun detectVendor(deviceName: String): EinkVendor {
        val normalized = deviceName.uppercase()
        return when {
            "BOOX" in normalized || "ONYX" in normalized -> EinkVendor.BOOX
            "BIGME" in normalized || "HIBREAK" in normalized -> EinkVendor.BIGME
            "HISENSE" in normalized -> EinkVendor.HISENSE
            "MEEBOOK" in normalized || "BOYUE" in normalized || "LIKEBOOK" in normalized -> EinkVendor.MEEBOOK
            "POCKETBOOK" in normalized -> EinkVendor.POCKETBOOK
            "INKPALM" in normalized || "MOAAN" in normalized || "MOAN" in normalized -> EinkVendor.INKPALM
            "NOOK" in normalized -> EinkVendor.NOOK
            "REMARKABLE" in normalized -> EinkVendor.REMARKABLE
            "KOBO" in normalized -> EinkVendor.KOBO_SIDELOAD
            "EINK" in normalized || "E-INK" in normalized || "EPD" in normalized -> EinkVendor.GENERIC_EINK
            else -> EinkVendor.NONE
        }
    }
}
