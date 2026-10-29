package com.enve.app.storyalign

import android.content.Context
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.engine.storyalign.StoryAlignEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

class StoryAlignPreferencesStore(context: Context, locations: ProfileStorageLocations) {
    private val preferences = context.getSharedPreferences("storyalign-${locations.profileId}", Context.MODE_PRIVATE)
    private val mutex = Mutex()
    private val mutableEngine = MutableStateFlow(
        StoryAlignEngine.entries.firstOrNull { it.name == preferences.getString(ENGINE_KEY, null) }
            ?: StoryAlignEngine.QUARTZNET_CTC,
    )
    val engine = mutableEngine.asStateFlow()

    suspend fun setEngine(engine: StoryAlignEngine) = mutex.withLock {
        withContext(Dispatchers.IO) {
            check(preferences.edit().putString(ENGINE_KEY, engine.name).commit()) { "Could not save the alignment method" }
        }
        mutableEngine.value = engine
    }

    companion object {
        private const val ENGINE_KEY = "engine"
    }
}
