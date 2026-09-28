package com.enve.app.di

import coil.intercept.Interceptor
import coil.network.HttpException
import coil.request.ErrorResult
import coil.request.ImageResult
import java.util.concurrent.ConcurrentHashMap

internal class MissingImageInterceptor : Interceptor {
    private val missing = ConcurrentHashMap<String, HttpException>()

    override suspend fun intercept(chain: Interceptor.Chain): ImageResult {
        val request = chain.request
        val url = request.data.toString().takeIf { it.startsWith("http://") || it.startsWith("https://") }
            ?: return chain.proceed(request)
        missing[url]?.let { return ErrorResult(request.error, request, it) }
        val result = chain.proceed(request)
        val notFound = (result as? ErrorResult)?.throwable as? HttpException
        if (notFound?.response?.code == HTTP_NOT_FOUND) missing[url] = notFound
        return result
    }

    private companion object {
        const val HTTP_NOT_FOUND = 404
    }
}
