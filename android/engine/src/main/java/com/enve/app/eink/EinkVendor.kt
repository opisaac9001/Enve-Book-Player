package com.enve.app.eink

enum class EinkVendor(val displayName: String) {
    BOOX("BOOX"),
    HISENSE("Hisense"),
    KOBO_SIDELOAD("Kobo"),
    REMARKABLE("reMarkable"),
    BIGME("Bigme"),
    MEEBOOK("Meebook"),
    POCKETBOOK("PocketBook"),
    INKPALM("InkPalm"),
    NOOK("NOOK"),
    GENERIC_EINK("Generic E-Ink"),
    NONE("Standard Display");

    val needsWebViewSoftwareLayer: Boolean
        get() = when (this) {

            BOOX,
            REMARKABLE,
            KOBO_SIDELOAD,
            MEEBOOK,
            POCKETBOOK,
            INKPALM,
            NOOK,
            GENERIC_EINK -> true

            HISENSE, BIGME, NONE -> false
        }
}
