// AGENT-LOCKED
package com.enve.storyteller.auth

import com.enve.core.data.remote.AuthHeaderContext
import com.enve.core.data.remote.AuthHeaderStrategy
import javax.inject.Inject

class StorytellerAuthHeaderStrategy @Inject constructor() : AuthHeaderStrategy {
    override fun apply(context: AuthHeaderContext): okhttp3.Request {
        val token = context.token.orEmpty()
        val authorization = if (
            token.startsWith("Bearer ", ignoreCase = true) ||
            token.startsWith("Basic ", ignoreCase = true)
        ) {
            token
        } else {
            "Bearer $token"
        }

        return context.builder
            .header("Authorization", authorization)
            .header("Cookie", "st_token=$token")
            .build()
    }
}
