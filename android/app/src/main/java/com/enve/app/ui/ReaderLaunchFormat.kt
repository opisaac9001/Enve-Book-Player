package com.enve.app.ui

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource

internal fun Book.readerFormat(): String? = when {

    (source == BookSource.STORYTELLER || source == BookSource.LOCAL) && readAlongAvailable -> "READALOUD"
    mediaType == AppMediaType.AUDIOBOOK && hasEbook -> "EPUB"
    else -> primaryFileType
}
