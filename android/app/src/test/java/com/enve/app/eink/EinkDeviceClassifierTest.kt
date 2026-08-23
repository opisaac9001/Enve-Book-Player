package com.enve.app.eink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EinkDeviceClassifierTest {
    @Test
    fun detectsBigmeHiBreakWhenRefreshRateWouldLookStandard() {
        assertEquals(
            EinkVendor.BIGME,
            EinkDeviceClassifier.detectVendor("Bigme Bigme Smartphone HiBreak"),
        )
        assertEquals(
            EinkVendor.BIGME,
            EinkDeviceClassifier.detectVendor("unknown unknown Smartphone HiBreak"),
        )
        assertFalse(EinkVendor.BIGME.needsWebViewSoftwareLayer)
    }

    @Test
    fun detectsCommonAndroidEinkVendors() {
        val cases = mapOf(
            "Onyx BOOX Palma" to EinkVendor.BOOX,
            "Hisense A9" to EinkVendor.HISENSE,
            "Meebook M7" to EinkVendor.MEEBOOK,
            "Boyue Likebook P78" to EinkVendor.MEEBOOK,
            "PocketBook InkPad Eo" to EinkVendor.POCKETBOOK,
            "Xiaomi Moaan InkPalm Plus" to EinkVendor.INKPALM,
            "Barnes NOOK GlowLight" to EinkVendor.NOOK,
            "Kobo Clara Android Sideload" to EinkVendor.KOBO_SIDELOAD,
            "reMarkable Paper Pro" to EinkVendor.REMARKABLE,
            "Generic EPD reader" to EinkVendor.GENERIC_EINK,
        )

        cases.forEach { (deviceName, expected) ->
            assertEquals(expected, EinkDeviceClassifier.detectVendor(deviceName))
        }
    }

    @Test
    fun standardAndroidDevicesAreNotClassifiedAsEink() {
        assertEquals(EinkVendor.NONE, EinkDeviceClassifier.detectVendor("Google lynx Pixel 7a"))
        assertEquals(EinkVendor.NONE, EinkDeviceClassifier.detectVendor("Samsung Galaxy Tab S10"))
    }

    @Test
    fun monochromeReaderVendorsUseSoftwareWebViewLayer() {
        assertTrue(EinkVendor.BOOX.needsWebViewSoftwareLayer)
        assertTrue(EinkVendor.MEEBOOK.needsWebViewSoftwareLayer)
        assertTrue(EinkVendor.POCKETBOOK.needsWebViewSoftwareLayer)
        assertTrue(EinkVendor.INKPALM.needsWebViewSoftwareLayer)
        assertTrue(EinkVendor.NOOK.needsWebViewSoftwareLayer)
    }
}
