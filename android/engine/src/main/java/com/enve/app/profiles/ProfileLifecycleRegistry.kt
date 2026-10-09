package com.enve.app.profiles

import java.util.concurrent.CopyOnWriteArrayList
import javax.inject.Inject
import javax.inject.Singleton

fun interface ProfileLifecycleParticipant {
    suspend fun checkpointAndClose()
}

@Singleton
class ProfileLifecycleRegistry @Inject constructor() {
    private data class Entry(val profileId: String, val participant: ProfileLifecycleParticipant)
    private val entries = CopyOnWriteArrayList<Entry>()

    fun register(profileId: String, participant: ProfileLifecycleParticipant): AutoCloseable {
        val entry = Entry(profileId, participant)
        entries += entry
        return AutoCloseable { entries.remove(entry) }
    }

    suspend fun checkpointAndClose(profileId: String) {
        entries.filter { it.profileId == profileId }.forEach { it.participant.checkpointAndClose() }
    }
}
