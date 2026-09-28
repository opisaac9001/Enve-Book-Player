package com.enve.app.data.opds

import okhttp3.ResponseBody
import retrofit2.Response
import retrofit2.http.GET
import retrofit2.http.Header
import retrofit2.http.Url

const val OPDS_CATALOG_ACCEPT: String =
    "application/opds+json, " +
        "application/opds-publication+json, " +
        "application/atom+xml;profile=opds-catalog;kind=acquisition, " +
        "application/atom+xml;profile=opds-catalog;kind=navigation, " +
        "application/atom+xml;profile=opds-catalog, " +
        "application/atom+xml;q=0.9, " +
        "application/json;q=0.8, " +
        "*/*;q=0.1"

interface OpdsCatalogApi {

    @GET
    suspend fun fetch(
        @Url url: String,
        @Header("Accept") accept: String,
    ): Response<ResponseBody>
}
