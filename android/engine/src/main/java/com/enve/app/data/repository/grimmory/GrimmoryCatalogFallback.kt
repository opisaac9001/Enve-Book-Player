package com.enve.app.data.repository.grimmory

import com.enve.app.data.remote.dto.BookSummaryDto

internal fun shouldUseLegacyGrimmoryCatalog(
    responseCode: Int,
    firstPageItemCount: Int?,
): Boolean = responseCode !in 200..299 || firstPageItemCount == null || firstPageItemCount == 0


internal fun consistentGrimmoryCatalogFallback(
    appBooks: List<BookSummaryDto>,
    legacyBooks: List<BookSummaryDto>,
): List<BookSummaryDto> {
    val legacyIds = legacyBooks.mapTo(HashSet()) { it.id }
    check(appBooks.all { it.id in legacyIds }) {
        "Grimmory catalog endpoints returned conflicting books"
    }
    return legacyBooks
}
