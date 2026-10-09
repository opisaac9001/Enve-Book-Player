package com.enve.core.data.sync

import com.enve.core.data.model.BookSource
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

@Singleton
class AudiobookProgressWriteCoordinator @Inject constructor() {
    private val mutexes = ConcurrentHashMap<String, Mutex>()

    suspend fun <T> ordered(source: BookSource, connectionId: String?, action: suspend () -> T): T {
        val key = "${source.name}:${connectionId.orEmpty()}"
        val held = currentCoroutineContext()[HeldWrites]?.keys.orEmpty()
        if (key in held) return action()
        return mutexes.getOrPut(key) { Mutex() }.withLock {
            withContext(HeldWrites(held + key)) { action() }
        }
    }

    private class HeldWrites(val keys: Set<String>) : AbstractCoroutineContextElement(Key) {
        companion object Key : CoroutineContext.Key<HeldWrites>
    }
}
