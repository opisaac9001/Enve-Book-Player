package com.enve.app.data.kavita

import java.time.Instant
import java.util.concurrent.atomic.AtomicReference
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class KavitaCoverRevisionStore @Inject constructor() {
    private val current = AtomicReference(Instant.now())
    val revision: Instant get() = current.get()

    fun invalidate() {
        current.updateAndGet { previous -> maxOf(Instant.now(), previous.plusMillis(1)) }
    }
}
