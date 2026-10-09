package com.enve.app.profiles

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.async
import kotlinx.coroutines.CancellationException
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ProfileRuntimeRegistry @Inject constructor(@ApplicationContext private val context: Context) {
    private val mutex = Mutex()
    private val blockedProfiles = mutableSetOf<String>()
    private val closingProfiles = mutableSetOf<String>()
    private val configuration = context.getSharedPreferences("family_profile_runtime", Context.MODE_PRIVATE)
    private val components = mutableMapOf<String, ProfileRuntimeComponent>()

    suspend fun open(profileId: String): ProfileRuntimeComponent = mutex.withLock { openLocked(profileId) }

    private suspend fun openLocked(profileId: String): ProfileRuntimeComponent {
        if (profileId in closingProfiles) throw CancellationException("Profile is closing")
        components[profileId]?.let { return it }
        val resources = ProfileResources.open(context, profileId)
        try {
            return DaggerProfileRuntimeComponent.factory().create(resources).also { component ->
                component.history()
                component.audioStorage()
                component.comicStorage()
                components[profileId] = component
            }
        } catch (error: Throwable) {
            resources.close()
            throw error
        }
    }

    suspend fun close(profileId: String) {
        val component = mutex.withLock {
            if (profileId in closingProfiles) return
            val captured = components.remove(profileId) ?: return
            closingProfiles += profileId
            captured
        }
        try {
            component.resources().close()
        } finally {
            withContext(NonCancellable) { mutex.withLock { closingProfiles -= profileId } }
        }
    }

    suspend fun block(profileId: String) = mutex.withLock {
        blockedProfiles += profileId
    }

    suspend fun unblock(profileId: String) = mutex.withLock {
        blockedProfiles -= profileId
    }

    suspend fun <T> withProfile(profileId: String, block: suspend (ProfileRuntimeComponent) -> T): T {
        val job = mutex.withLock {
            val selected = if (configuration.getBoolean("enabled", false)) {
                configuration.getString("selected", DEFAULT_ADULT_PROFILE_ID)
            } else DEFAULT_ADULT_PROFILE_ID
            if (profileId in blockedProfiles || selected != profileId) throw CancellationException("Profile is inactive")
            val component = openLocked(profileId)
            component.resources().scope.async { block(component) }
        }
        try {
            return job.await()
        } finally {
            withContext(NonCancellable) { job.cancelAndJoin() }
        }
    }
}
