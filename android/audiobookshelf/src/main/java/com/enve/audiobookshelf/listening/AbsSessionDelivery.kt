package com.enve.audiobookshelf.listening

import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException

class AbsPlaybackSessionHttpException(val code: Int, action: String) :
    IllegalStateException("Audiobookshelf playback session $action failed: HTTP $code")

object AbsSessionDelivery {
    fun mayHaveApplied(error: Throwable): Boolean = when (error) {
        is AbsPlaybackSessionHttpException -> error.code >= 500
        is ConnectException, is UnknownHostException, is NoRouteToHostException, is SSLHandshakeException ->
            error.suppressed.any(::mayHaveApplied)
        is IOException -> true
        else -> false
    }
}
