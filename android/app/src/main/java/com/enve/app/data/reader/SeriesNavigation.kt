package com.enve.app.data.reader

import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReadStatus
import com.enve.hearth.library.ComicSeriesGrouping

internal suspend fun BookCacheDao.nextBookInSeries(
    bookId: String,
    connectionId: String?,
): Book? {
    val cached = getByIdAndConnection(bookId, connectionId) ?: if (connectionId == null) getById(bookId) else null
    val currentBook = cached?.toBook() ?: return null
    val books = currentBook.comic?.let { comicRun(currentBook, it.seriesId) } ?: namedSeries(currentBook) ?: return null
    val currentIndex = books.indexOfFirst { it.id == currentBook.id }
    if (currentIndex < 0) return null
    return books.drop(currentIndex + 1).firstOrNull { !it.isReadForNextInSeries() }
}

private suspend fun BookCacheDao.comicRun(current: Book, seriesId: String): List<Book> =
    ComicSeriesGrouping.of(
        comicsInSeries(seriesId, current.source.name, current.connectionId, current.libraryId).map { it.toBook() },
    ).orderedBooks

private suspend fun BookCacheDao.namedSeries(current: Book): List<Book>? {
    val seriesName = current.seriesName?.trim()?.takeIf { it.isNotBlank() } ?: return null
    return booksWhereSeries(seriesName)
        .map { it.toBook() }
        .filter { it.source == current.source && it.connectionId == current.connectionId }
}

internal fun Book.isReadForNextInSeries(): Boolean =
    isFinished || readStatus == ReadStatus.COMPLETED || readProgress >= 0.999f || (epubProgress ?: 0f) >= 0.999f
