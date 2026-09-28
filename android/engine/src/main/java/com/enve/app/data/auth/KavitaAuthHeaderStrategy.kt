package com.enve.app.data.auth

import com.enve.core.data.remote.AuthHeaderContext
import com.enve.core.data.remote.AuthHeaderStrategy
import okhttp3.Request
import javax.inject.Inject

class KavitaAuthHeaderStrategy @Inject constructor() : AuthHeaderStrategy {
    override fun apply(context: AuthHeaderContext): Request {
        val token = context.token.orEmpty()
        if (token.isBlank()) return context.builder.build()

        return if (token.count { it == '.' } == 2) {
            context.builder.header("Authorization", "Bearer $token").build()
        } else {
            context.builder.header("X-API-Key", token).build()
        }
    }
}
