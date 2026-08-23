package com.enve.engine.sleep

enum class SleepDataAccess {
    AVAILABLE,
    PERMISSION_REQUIRED,
    PROVIDER_UPDATE_REQUIRED,
    UNSUPPORTED,
    ERROR,
}

enum class SleepStageKind {
    AWAKE,
    LIGHT,
    DEEP,
    REM,
    ASLEEP,
    UNKNOWN,
}

data class SleepStageSegment(
    val startTimeMs: Long,
    val endTimeMs: Long,
    val kind: SleepStageKind,
)

data class SleepPeriod(
    val id: String,
    val sleepDayEpochDay: Long,
    val startTimeMs: Long,
    val sleepOnsetTimeMs: Long,
    val endTimeMs: Long,
    val totalSleepMs: Long,
    val stages: List<SleepStageSegment>,
    val stageDurationsMs: Map<SleepStageKind, Long>,
    val latencyMs: Long?,
    val efficiency: Double?,
    val awakenings: Int,
    val hasDetailedStages: Boolean,
    val isNap: Boolean,
    val sourceName: String,
    val sourcePackage: String,
)

data class SleepDataSnapshot(
    val access: SleepDataAccess,
    val periods: List<SleepPeriod> = emptyList(),
)

interface SleepDataFacade {
    suspend fun load(daysBack: Int = 30): SleepDataSnapshot
}
