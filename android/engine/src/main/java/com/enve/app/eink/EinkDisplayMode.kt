package com.enve.app.eink

enum class EinkDisplayMode(val displayName: String) {
    AUTO("Auto"),
    ON("Mono"),
    ON_COLOR("Color"),
    OFF("Off");

    val optimizationsActive: Boolean
        get() = this == ON || this == ON_COLOR

    val forcesMonochromeTheme: Boolean
        get() = this == ON

    companion object {
        fun fromString(value: String): EinkDisplayMode {
            return entries.find { it.name.equals(value, ignoreCase = true) } ?: AUTO
        }
    }
}
