package com.enve.core.data.model

fun Book.isVisibleLibraryBook(
    excludedLibraryIds: Set<String>,
    disabledConnectionIds: Set<String> = emptySet(),
): Boolean =
    (libraryId == null || libraryId !in excludedLibraryIds) && connectionId !in disabledConnectionIds

fun List<Book>.visibleLibraryBooks(
    excludedLibraryIds: Set<String>,
    disabledConnectionIds: Set<String> = emptySet(),
): List<Book> =
    asSequence()
        .filter { book -> book.isVisibleLibraryBook(excludedLibraryIds, disabledConnectionIds) }
        .distinctBy { book -> "${book.source.name}:${book.id.ifBlank { book.title }}" }
        .toList()
