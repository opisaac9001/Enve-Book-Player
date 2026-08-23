package com.enve.app.ui.screens

import android.content.Context
import android.content.Intent
import com.enve.app.ui.readerFormat
import com.enve.core.data.model.Book

internal fun Context.readerIntentForBook(book: Book, hearthChrome: Boolean): Intent {
    val readerFormat = book.readerFormat()
    return when (readerFormat?.uppercase()) {
        "PDF" -> PdfReaderActivity.createIntent(
            context = this,
            bookId = book.id,
            bookSource = book.source,
            connectionId = book.connectionId,
            title = book.title,
            author = book.author.orEmpty(),
            locator = book.epubLocator,
        ).apply { putExtra(PdfReaderActivity.EXTRA_HEARTH_CHROME, hearthChrome) }
        "CBZ", "CBX", "CBR" -> ComicReaderActivity.createIntent(
            context = this,
            bookId = book.id,
            bookSource = book.source,
            connectionId = book.connectionId,
            title = book.title,
            author = book.author.orEmpty(),
            format = readerFormat,
            locator = book.epubLocator,
        ).apply { putExtra(ComicReaderActivity.EXTRA_HEARTH_CHROME, hearthChrome) }
        else -> EbookReaderActivity.createIntent(
            context = this,
            bookId = book.id,
            bookSource = book.source,
            connectionId = book.connectionId,
            title = book.title,
            author = book.author.orEmpty(),
            bookFormat = readerFormat,
            epubLocator = book.epubLocator,
            epubProgress = book.epubProgress ?: book.readProgress,
            lastReadTime = book.lastReadTime,
        ).apply { putExtra(EbookReaderActivity.EXTRA_HEARTH_CHROME, hearthChrome) }
    }
}
