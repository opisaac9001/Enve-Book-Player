package com.enve.core.data.remote

import java.io.IOException
import java.util.Collections
import java.util.WeakHashMap
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.Interceptor
import okhttp3.Response

class RequestScopeInterceptor : Interceptor, EventListener.Factory {
    private class Scope(val connectionId: String?, val login: LoginAttempt?)
    private val scopes = Collections.synchronizedMap(WeakHashMap<Call, Scope>())

    override fun create(call: Call): EventListener {
        scopes[call] = Scope(ConnectionScope.getConnectionId(), LoginAttemptScope.get())
        return object : EventListener() {
            override fun callEnd(call: Call) { scopes.remove(call) }
            override fun callFailed(call: Call, ioe: IOException) { scopes.remove(call) }
        }
    }

    override fun intercept(chain: Interceptor.Chain): Response {
        val scope = scopes[chain.call()]
        return ConnectionScope.withConnectionId(scope?.connectionId) {
            LoginAttemptScope.withAttempt(scope?.login) { chain.proceed(chain.request()) }
        }
    }
}
