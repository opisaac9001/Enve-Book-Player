package com.enve.core.data.model

enum class VolumeLevelingStrength {
    OFF,
    LOW,
    MEDIUM,
    HIGH;

    companion object {
        fun fromString(value: String?): VolumeLevelingStrength =
            entries.firstOrNull { it.name.equals(value, ignoreCase = true) } ?: OFF
    }
}
