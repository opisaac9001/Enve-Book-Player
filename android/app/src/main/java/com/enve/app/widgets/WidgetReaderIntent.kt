package com.enve.app.widgets

import android.content.Context
import android.content.Intent
import androidx.glance.GlanceId
import androidx.glance.action.Action
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import com.enve.app.MainActivity
import com.enve.app.ui.screens.ComicReaderActivity
import com.enve.app.ui.screens.EbookReaderActivity
import com.enve.app.ui.screens.PdfReaderActivity
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import kotlinx.serialization.encodeToString

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
        ).apply { putExtra(PdfReaderActivity.EXTRA_HEARTH_CHROME, true) }
        "CBZ", "CBX", "CBR" -> ComicReaderActivity.createIntent(
            context = this, bookId = book.id, bookSource = book.source,
            connectionId = book.connectionId, title = book.title, author = book.author.orEmpty(),
            format = readerFormat, locator = book.epubLocator,
        ).apply { putExtra(ComicReaderActivity.EXTRA_HEARTH_CHROME, true) }
        else -> EbookReaderActivity.createIntent(
            context = this, bookId = book.id, bookSource = book.source,
            connectionId = book.connectionId, title = book.title, author = book.author.orEmpty(),
            bookFormat = readerFormat, epubLocator = book.epubLocator,
            epubProgress = book.epubProgress ?: book.readProgress, lastReadTime = book.lastReadTime,
        ).apply { putExtra(EbookReaderActivity.EXTRA_HEARTH_CHROME, true) }
    }
}

private val ReaderBookJsonKey = ActionParameters.Key<String>("reader_book_json")

internal fun readerAction(book: Book): Action = actionRunCallback<OpenReaderAction>(
    actionParametersOf(ReaderBookJsonKey to BookWidgetStore.json.encodeToString(book)),
)

class OpenReaderAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val json = parameters[ReaderBookJsonKey] ?: return
        val book = runCatching { BookWidgetStore.json.decodeFromString<Book>(json) }.getOrNull() ?: return
        val mainIntent = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivities(arrayOf(mainIntent, context.readerIntentFor(book)))
    }
}
