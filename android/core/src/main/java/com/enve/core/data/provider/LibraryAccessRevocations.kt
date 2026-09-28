package com.enve.core.data.provider

import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

data class RevokedLibrary(val connectionId: String, val libraryId: String)

@Singleton
class LibraryAccessRevocations @Inject constructor() {
    private val _revoked = MutableSharedFlow<RevokedLibrary>(
        extraBufferCapacity = 16,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val revoked: SharedFlow<RevokedLibrary> = _revoked.asSharedFlow()

    fun revoke(connectionId: String, libraryId: String) {
        _revoked.tryEmit(RevokedLibrary(connectionId, libraryId))
    }
}
