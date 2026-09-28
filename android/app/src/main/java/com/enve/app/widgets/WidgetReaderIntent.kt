package com.enve.app.widgets

import android.content.Context
import android.content.Intent
import com.enve.app.ui.screens.ComicReaderActivity
import com.enve.app.ui.screens.EbookReaderActivity
import com.enve.app.ui.screens.PdfReaderActivity
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource

internal fun Context.widgetReaderIntentFor(book: Book): Intent {
    val readerIntent = readerIntentFor(book)
    return Intent(this, WidgetReaderActivity::class.java).putExtras(readerIntent).putExtra(
        WidgetReaderActivity.EXTRA_READER_CLASS, requireNotNull(readerIntent.component).className,
    )
}

internal fun Context.readerIntentFor(book: Book): Intent {
    val readerFormat = when {
        (book.source == BookSource.STORYTELLER || book.source == BookSource.LOCAL) && book.readAlongAvailable -> "READALOUD"
        book.mediaType == AppMediaType.AUDIOBOOK && book.hasEbook -> "EPUB"
        else -> book.primaryFileType
    }
    return when (readerFormat?.uppercase()) {
        "PDF" -> PdfReaderActivity.createIntent(
            context = this, bookId = book.id, bookSource = book.source,
            connectionId = book.connectionId, title = book.title, author = book.author.orEmpty(),
            locator = book.epubLocator,
        )
        "CBZ", "CBX", "CBR" -> ComicReaderActivity.createIntent(
            context = this, bookId = book.id, bookSource = book.source,
            connectionId = book.connectionId, title = book.title, author = book.author.orEmpty(),
            format = readerFormat, locator = book.epubLocator,
        )
        else -> EbookReaderActivity.createIntent(
            context = this, bookId = book.id, bookSource = book.source,
            connectionId = book.connectionId, title = book.title, author = book.author.orEmpty(),
            bookFormat = readerFormat, epubLocator = book.epubLocator,
            epubProgress = book.epubProgress ?: book.readProgress, lastReadTime = book.lastReadTime,
        )
    }
}
