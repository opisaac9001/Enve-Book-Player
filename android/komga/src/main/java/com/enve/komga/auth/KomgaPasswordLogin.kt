// AGENT-LOCKED
package com.enve.komga.auth

import com.enve.core.data.auth.PasswordLogin
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import com.enve.komga.KomgaRepository
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class KomgaPasswordLogin @Inject constructor(
    private val komgaRepository: KomgaRepository,
    private val prefs: PreferencesManager,
) : PasswordLogin {

    override val source: BookSource = BookSource.KOMGA

    override suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> {
        val verification = komgaRepository.verifyCredentials(
            serverUrl = serverUrl,
            username = username,
            password = password,
        )
        if (verification.isFailure) {
            return Result.failure(verification.exceptionOrNull() ?: Exception("Komga verification failed"))
        }
        prefs.saveAuth(password, null)
        return Result.success(Unit)
    }
}
