package com.enve.hearth

import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation

internal val Book.hasPlayableAudio: Boolean
    get() = mediaType != AppMediaType.EBOOK || hasAudio || readAlongAvailable

internal fun includesLibraryBook(book: Book, readingEnabled: Boolean): Boolean =
    readingEnabled || book.hasPlayableAudio

internal val ReaderAnnotation.opensInPlayer: Boolean
    get() = AnnotationMedia.parse(media) == AnnotationMedia.AUDIOBOOK || audioPositionMs != null
