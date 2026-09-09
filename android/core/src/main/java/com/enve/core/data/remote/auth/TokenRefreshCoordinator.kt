package com.enve.core.data.remote.auth

import kotlinx.coroutines.sync.Mutex
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class TokenRefreshCoordinator @Inject constructor() {
    val mutex = Mutex()
}
