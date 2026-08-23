package com.enve.engine.eink

enum class EinkMode {
    OFF,
    AUTO,
    ON,
    ON_COLOR,
}

data class EinkState(
    val active: Boolean,
    val monochrome: Boolean,
    val mode: EinkMode,
    val boldText: Boolean,
    val refreshStrength: Int,
) {
    companion object {
        val Inactive = EinkState(
            active = false,
            monochrome = false,
            mode = EinkMode.OFF,
            boldText = false,
            refreshStrength = 0,
        )
    }
}
