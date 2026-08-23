// AGENT-LOCKED
package com.enve.app.data.jellyfin

import com.enve.core.data.auth.PasswordLogin
import com.enve.app.data.mediabrowser.MediaBrowserPasswordAuthenticator
import com.enve.core.data.model.BookSource
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class JellyfinPasswordLogin @Inject constructor(
    private val authenticator: MediaBrowserPasswordAuthenticator,
) : PasswordLogin {

    override val source: BookSource = BookSource.JELLYFIN

    override suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> =
        authenticator.login(source, username, password)
}
