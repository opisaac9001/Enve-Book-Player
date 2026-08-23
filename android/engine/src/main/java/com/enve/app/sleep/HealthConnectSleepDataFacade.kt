package com.enve.app.sleep

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import com.enve.engine.sleep.SleepDataAccess
import com.enve.engine.sleep.SleepDataFacade
import com.enve.engine.sleep.SleepDataSnapshot
import com.enve.engine.sleep.SleepPeriod
import com.enve.engine.sleep.SleepStageKind
import com.enve.engine.sleep.SleepStageSegment
import dagger.hilt.android.qualifiers.ApplicationContext
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.CancellationException
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class HealthConnectSleepDataFacade @Inject constructor(
    @ApplicationContext private val context: Context,
) : SleepDataFacade {
    override suspend fun load(daysBack: Int): SleepDataSnapshot {
        return when (HealthConnectClient.getSdkStatus(context)) {
            HealthConnectClient.SDK_UNAVAILABLE -> SleepDataSnapshot(SleepDataAccess.UNSUPPORTED)
            HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED ->
                SleepDataSnapshot(SleepDataAccess.PROVIDER_UPDATE_REQUIRED)
            HealthConnectClient.SDK_AVAILABLE -> loadAvailable(daysBack)
            else -> SleepDataSnapshot(SleepDataAccess.ERROR)
        }
    }

    private suspend fun loadAvailable(daysBack: Int): SleepDataSnapshot {
        return try {
            val client = HealthConnectClient.getOrCreate(context)
            val permission = HealthPermission.getReadPermission(SleepSessionRecord::class)
            if (permission !in client.permissionController.getGrantedPermissions()) {
                return SleepDataSnapshot(SleepDataAccess.PERMISSION_REQUIRED)
            }
            val end = Instant.now()
            val start = end.minus(Duration.ofDays(daysBack.coerceIn(1, 30).toLong()))
            val records = readAll(client, start, end)
            SleepDataSnapshot(
                access = SleepDataAccess.AVAILABLE,
                periods = selectPeriods(records.mapNotNull(::mapRecord)),
            )
        } catch (error: CancellationException) {
            throw error
        } catch (_: SecurityException) {
            SleepDataSnapshot(SleepDataAccess.PERMISSION_REQUIRED)
        } catch (_: Exception) {
            SleepDataSnapshot(SleepDataAccess.ERROR)
        }
    }

    private suspend fun readAll(
        client: HealthConnectClient,
        start: Instant,
        end: Instant,
    ): List<SleepSessionRecord> {
        val records = mutableListOf<SleepSessionRecord>()
        var pageToken: String? = null
        do {
            val response = client.readRecords(
                ReadRecordsRequest(
                    recordType = SleepSessionRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(start, end),
                    ascendingOrder = false,
                    pageSize = 500,
                    pageToken = pageToken,
                ),
            )
            records += response.records
            pageToken = response.pageToken
        } while (pageToken != null)
        return records
    }

    private fun mapRecord(record: SleepSessionRecord): SleepPeriod? {
        val sessionMs = Duration.between(record.startTime, record.endTime).toMillis()
        if (sessionMs < MIN_PERIOD_MS) return null
        val stages = record.stages
            .mapNotNull { stage ->
                val start = maxOf(stage.startTime, record.startTime)
                val end = minOf(stage.endTime, record.endTime)
                if (end <= start) null else SleepStageSegment(
                    startTimeMs = start.toEpochMilli(),
                    endTimeMs = end.toEpochMilli(),
                    kind = stageKind(stage.stage),
                )
            }
            .sortedBy(SleepStageSegment::startTimeMs)
        val asleepStages = stages.filter { it.kind.isAsleep }
        val totalSleepMs = asleepStages.sumOf { it.endTimeMs - it.startTimeMs }
            .takeIf { it > 0L } ?: sessionMs
        val onsetMs = asleepStages.firstOrNull()?.startTimeMs ?: record.startTime.toEpochMilli()
        val stageDurations = stages.groupBy(SleepStageSegment::kind).mapValues { (_, values) ->
            values.sumOf { it.endTimeMs - it.startTimeMs }
        }
        val sourcePackage = record.metadata.dataOrigin.packageName
        return SleepPeriod(
            id = record.metadata.id.ifBlank {
                "$sourcePackage:${record.startTime.toEpochMilli()}:${record.endTime.toEpochMilli()}"
            },
            sleepDayEpochDay = record.startTime.atZone(ZoneId.systemDefault()).minusHours(12).toLocalDate().toEpochDay(),
            startTimeMs = record.startTime.toEpochMilli(),
            sleepOnsetTimeMs = onsetMs,
            endTimeMs = record.endTime.toEpochMilli(),
            totalSleepMs = totalSleepMs,
            stages = stages,
            stageDurationsMs = stageDurations,
            latencyMs = if (stages.isEmpty()) null else (onsetMs - record.startTime.toEpochMilli()).coerceAtLeast(0L),
            efficiency = if (stages.isEmpty()) null else (totalSleepMs.toDouble() / sessionMs).coerceIn(0.0, 1.0),
            awakenings = stages.count {
                it.kind == SleepStageKind.AWAKE &&
                    it.startTimeMs >= onsetMs &&
                    it.endTimeMs - it.startTimeMs >= MIN_AWAKENING_MS
            },
            hasDetailedStages = stages.any { it.kind in detailedStages },
            isNap = false,
            sourceName = sourceName(sourcePackage),
            sourcePackage = sourcePackage,
        )
    }

    private fun selectPeriods(periods: List<SleepPeriod>): List<SleepPeriod> {
        return periods.groupBy(SleepPeriod::sleepDayEpochDay).values.flatMap { dayPeriods ->
            val ranked = dayPeriods.sortedWith(
                compareByDescending<SleepPeriod> { it.totalSleepMs + detailedDuration(it) }
                    .thenByDescending(SleepPeriod::endTimeMs),
            )
            val main = ranked.first()
            buildList {
                add(main)
                ranked.drop(1)
                    .filter { overlapFraction(it, main) < MAX_DUPLICATE_OVERLAP }
                    .forEach { add(it.copy(isNap = true)) }
            }
        }.sortedByDescending(SleepPeriod::startTimeMs)
    }

    private fun detailedDuration(period: SleepPeriod): Long =
        detailedStages.sumOf { period.stageDurationsMs[it] ?: 0L }

    private fun overlapFraction(first: SleepPeriod, second: SleepPeriod): Double {
        val overlap = (minOf(first.endTimeMs, second.endTimeMs) - maxOf(first.startTimeMs, second.startTimeMs))
            .coerceAtLeast(0L)
        val shorter = minOf(first.endTimeMs - first.startTimeMs, second.endTimeMs - second.startTimeMs)
        return if (shorter > 0L) overlap.toDouble() / shorter else 0.0
    }

    private fun sourceName(packageName: String): String {
        return try {
            val info = context.packageManager.getApplicationInfo(packageName, 0)
            context.packageManager.getApplicationLabel(info).toString()
        } catch (_: Exception) {
            packageName.substringAfterLast('.').replaceFirstChar(Char::uppercase)
        }
    }

    private fun stageKind(stage: Int): SleepStageKind = when (stage) {
        SleepSessionRecord.STAGE_TYPE_AWAKE,
        SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED,
        SleepSessionRecord.STAGE_TYPE_OUT_OF_BED -> SleepStageKind.AWAKE
        SleepSessionRecord.STAGE_TYPE_LIGHT -> SleepStageKind.LIGHT
        SleepSessionRecord.STAGE_TYPE_DEEP -> SleepStageKind.DEEP
        SleepSessionRecord.STAGE_TYPE_REM -> SleepStageKind.REM
        SleepSessionRecord.STAGE_TYPE_SLEEPING -> SleepStageKind.ASLEEP
        else -> SleepStageKind.UNKNOWN
    }

    private val SleepStageKind.isAsleep: Boolean
        get() = this == SleepStageKind.LIGHT || this == SleepStageKind.DEEP ||
            this == SleepStageKind.REM || this == SleepStageKind.ASLEEP

    private companion object {
        const val MIN_PERIOD_MS = 20L * 60L * 1_000L
        const val MIN_AWAKENING_MS = 60_000L
        const val MAX_DUPLICATE_OVERLAP = 0.5
        val detailedStages = setOf(SleepStageKind.LIGHT, SleepStageKind.DEEP, SleepStageKind.REM)
    }
}
