package com.enve.app.data.podcasts

import android.content.Context
import android.content.SharedPreferences
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.engine.podcasts.PodcastRoutine
import com.enve.engine.podcasts.PodcastRoutineLimits
import com.enve.engine.podcasts.PodcastRoutinePick
import com.enve.engine.podcasts.PodcastRoutineRule
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.Collections
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

private const val PREFERENCES_NAME = "podcast_routines"
private const val ROUTINES_KEY = "routines"

@Singleton
class PodcastRoutineStore(private val preferences: SharedPreferences) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE),
    )

    constructor(context: Context, locations: ProfileStorageLocations) : this(
        context.getSharedPreferences(
            if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) PREFERENCES_NAME
            else "${PREFERENCES_NAME}_profile_${locations.profileId}",
            Context.MODE_PRIVATE,
        ),
    )

    private val json = Json { ignoreUnknownKeys = true }
    private val mutableRoutines = MutableStateFlow(
        preferences.getString(ROUTINES_KEY, null)?.let { stored ->
            runCatching { json.decodeFromString<List<PodcastRoutine>>(stored) }.getOrNull()
        }.orEmpty().map(::sanitized),
    )

    val routines: StateFlow<List<PodcastRoutine>> = mutableRoutines

    @Synchronized
    fun create(name: String, rules: List<PodcastRoutineRule>): PodcastRoutine? {
        if (mutableRoutines.value.size >= PodcastRoutineLimits.MAX_ROUTINES) return null
        val routine = sanitized(PodcastRoutine(UUID.randomUUID().toString(), name, rules))
        persist(mutableRoutines.value + routine)
        return routine
    }

    @Synchronized
    fun save(routine: PodcastRoutine) {
        val current = mutableRoutines.value
        val index = current.indexOfFirst { it.id == routine.id }
        val updated = sanitized(routine)
        if (index < 0 || current[index] == updated) return
        persist(current.toMutableList().apply { set(index, updated) })
    }

    @Synchronized
    fun delete(id: String) {
        val current = mutableRoutines.value
        val updated = current.filterNot { it.id == id }
        if (updated.size != current.size) persist(updated)
    }

    @Synchronized
    fun move(id: String, delta: Int) {
        val current = mutableRoutines.value
        val source = current.indexOfFirst { it.id == id }
        val target = source + delta
        if (source < 0 || target !in current.indices) return
        persist(current.toMutableList().apply { Collections.swap(this, source, target) })
    }

    private fun persist(routines: List<PodcastRoutine>) {
        preferences.edit().putString(ROUTINES_KEY, json.encodeToString(routines)).apply()
        mutableRoutines.value = routines
    }

    companion object {
        fun sanitized(routine: PodcastRoutine): PodcastRoutine {
            val name = routine.name.trim()
            return routine.copy(
                name = if (name.isEmpty()) PodcastRoutineLimits.DEFAULT_NAME else name.take(PodcastRoutineLimits.MAX_NAME_LENGTH),
                rules = routine.rules.take(PodcastRoutineLimits.MAX_RULES).map { rule ->
                    val pick = rule.pick
                    if (pick is PodcastRoutinePick.NextUnplayed) {
                        rule.copy(pick = PodcastRoutinePick.NextUnplayed(pick.count.coerceIn(PodcastRoutineLimits.episodeCounts)))
                    } else rule
                },
            )
        }
    }
}
