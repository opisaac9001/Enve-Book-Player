package com.enve.core.data.local

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf

internal class PendingPublisherStyles {
    internal data class Write(val revision: Long, val value: Boolean)

    private val pending = MutableStateFlow<Write?>(null)
    private var revision = 0L

    @OptIn(ExperimentalCoroutinesApi::class)
    fun overlay(persisted: Flow<Boolean>): Flow<Boolean> = pending
        .flatMapLatest { write -> write?.let { flowOf(it.value) } ?: persisted }
        .distinctUntilChanged()

    @Synchronized
    fun begin(value: Boolean): Write {
        val write = Write(++revision, value)
        pending.value = write
        return write
    }

    fun complete(write: Write) {
        pending.compareAndSet(write, null)
    }
}
