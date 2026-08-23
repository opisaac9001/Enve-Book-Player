package com.enve.app.data.repository.grimmory

internal fun shouldUseLegacyGrimmoryCatalog(
    responseCode: Int,
    firstPageItemCount: Int?,
): Boolean = responseCode !in 200..299 || firstPageItemCount == null || firstPageItemCount == 0
