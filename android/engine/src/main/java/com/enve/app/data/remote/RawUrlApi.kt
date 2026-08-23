package com.enve.app.data.remote

import okhttp3.ResponseBody
import retrofit2.Response
import retrofit2.http.GET
import retrofit2.http.Header
import retrofit2.http.Url

interface RawUrlApi {
    @GET
    suspend fun fetch(
        @Url url: String,
        @Header("Authorization") authorization: String? = null,
    ): Response<ResponseBody>
}
