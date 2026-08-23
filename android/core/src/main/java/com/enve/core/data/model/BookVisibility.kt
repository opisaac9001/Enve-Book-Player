package com.enve.core.data.model

fun Book.isVisibleLibraryBook(excludedLibraryIds: Set<String>): Boolean =
    libraryId == null || libraryId !in excludedLibraryIds

fun List<Book>.visibleLibraryBooks(excludedLibraryIds: Set<String>): List<Book> =
    asSequence()
        .filter { book -> book.isVisibleLibraryBook(excludedLibraryIds) }
        .distinctBy { book -> "${book.source.name}:${book.id.ifBlank { book.title }}" }
        .toList()
