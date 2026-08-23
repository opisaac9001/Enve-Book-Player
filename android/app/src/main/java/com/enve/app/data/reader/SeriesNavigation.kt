package com.enve.app.data.reader

import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReadStatus

internal suspend fun BookCacheDao.nextBookInSeries(
    bookId: String,
    connectionId: String?,
): Book? {
    val current = getByIdAndConnection(bookId, connectionId) ?: getById(bookId) ?: return null
    val currentBook = current.toBook()
    val seriesName = currentBook.seriesName?.trim()?.takeIf { it.isNotBlank() } ?: return null
    val books = booksWhereSeries(seriesName)
        .map { it.toBook() }
        .filter { it.source == currentBook.source && it.connectionId == currentBook.connectionId }
    val currentIndex = books.indexOfFirst { it.id == currentBook.id }
    if (currentIndex < 0) return null
    return books.drop(currentIndex + 1).firstOrNull { !it.isReadForNextInSeries() }
}

internal fun Book.isReadForNextInSeries(): Boolean =
    isFinished || readStatus == ReadStatus.COMPLETED || readProgress >= 0.999f || (epubProgress ?: 0f) >= 0.999f
