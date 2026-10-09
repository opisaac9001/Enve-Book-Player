package com.enve.app.hearth

import android.content.Context
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.engine.matching.BatchMatchingFacade
import com.enve.engine.matching.PendingMetadataMatch
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import javax.inject.Inject

class BatchMatchingFacadeImpl @Inject constructor(
    @ApplicationContext context: Context,
    private val locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
) : BatchMatchingFacade {
    private val prefs = context.getSharedPreferences(if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) "matching_review" else "matching_review_profile_${locations.profileId}", Context.MODE_PRIVATE)
    private val mutablePending = MutableStateFlow(readPending())
    override val pending: StateFlow<List<PendingMetadataMatch>> = mutablePending
    private val mutableThreshold = MutableStateFlow(prefs.getInt("auto_threshold", 95))
    override val threshold: StateFlow<Int> = mutableThreshold

    override suspend fun setThreshold(percent: Int) {
        val value = percent.coerceIn(70, 95)
        prefs.edit().putInt("auto_threshold", value).apply()
        mutableThreshold.value = value
    }

    override suspend fun queue(entry: PendingMetadataMatch) {
        save(mutablePending.value.filterNot { it.bookKey == entry.bookKey } + entry)
    }

    override suspend fun remove(bookKey: String) {
        save(mutablePending.value.filterNot { it.bookKey == bookKey })
    }

    override suspend fun clear() { save(emptyList()) }

    private fun save(entries: List<PendingMetadataMatch>) {
        val json = JSONArray()
        entries.forEach { entry ->
            json.put(JSONObject()
                .put("bookKey", entry.bookKey)
                .put("title", entry.title)
                .put("candidateId", entry.candidateId)
                .put("sourceName", entry.sourceName)
                .put("confidence", entry.confidence))
        }
        prefs.edit().putString("pending", json.toString()).apply()
        mutablePending.value = entries
    }

    private fun readPending(): List<PendingMetadataMatch> {
        return runCatching {
            val json = JSONArray(prefs.getString("pending", "[]"))
            (0 until json.length()).map { index ->
                val item = json.getJSONObject(index)
                PendingMetadataMatch(
                    bookKey = item.getString("bookKey"),
                    title = item.getString("title"),
                    candidateId = item.getString("candidateId"),
                    sourceName = item.getString("sourceName"),
                    confidence = item.getDouble("confidence"),
                )
            }
        }.getOrDefault(emptyList())
    }
}
