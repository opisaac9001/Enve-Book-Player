package com.enve.app.data.duplicates

import android.content.Context
import android.content.SharedPreferences
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class DuplicateGroupStore(private val prefs: SharedPreferences) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(
        context.getSharedPreferences("duplicate_groups", Context.MODE_PRIVATE),
    )

    constructor(context: Context, locations: ProfileStorageLocations) : this(
        context.getSharedPreferences(
            if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) "duplicate_groups"
            else "duplicate_groups_profile_${locations.profileId}",
            Context.MODE_PRIVATE,
        ),
    )

    private val mutableGroups = MutableStateFlow(readGroups())
    val groups: StateFlow<Map<String, String>> = mutableGroups

    fun group(bookKeys: List<String>, keeperKey: String): Int {
        require(keeperKey in bookKeys)
        val hidden = bookKeys.distinct().filterNot { it == keeperKey }
        val next = mutableGroups.value.toMutableMap()
        hidden.forEach { next[it] = keeperKey }
        save(next)
        return hidden.size
    }

    fun ungroup(keeperKey: String): Int {
        val next = mutableGroups.value.toMutableMap()
        val removed = next.values.count { it == keeperKey }
        next.entries.removeAll { it.value == keeperKey }
        save(next)
        return removed
    }

    private fun save(groups: Map<String, String>) {
        prefs.edit().putString("members", JSONObject(groups).toString()).apply()
        mutableGroups.value = groups
    }

    private fun readGroups(): Map<String, String> = runCatching {
        val json = JSONObject(prefs.getString("members", "{}") ?: "{}")
        json.keys().asSequence().associateWith(json::getString)
    }.getOrDefault(emptyMap())
}
