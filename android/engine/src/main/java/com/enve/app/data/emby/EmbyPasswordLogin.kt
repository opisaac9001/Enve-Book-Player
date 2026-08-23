// AGENT-LOCKED
package com.enve.app.data.emby

import com.enve.core.data.auth.PasswordLogin
import com.enve.app.data.mediabrowser.MediaBrowserPasswordAuthenticator
import com.enve.core.data.model.BookSource
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class EmbyPasswordLogin @Inject constructor(
    private val authenticator: MediaBrowserPasswordAuthenticator,
) : PasswordLogin {

    override val source: BookSource = BookSource.EMBY

    override suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> =
        authenticator.login(source, username, password)
}
