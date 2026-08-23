package com.enve.engine.annotations

import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import kotlinx.coroutines.flow.Flow

interface AnnotationsFacade {
    val knownTags: Flow<List<String>>

    fun annotationsForBook(bookId: String): Flow<List<ReaderAnnotation>>
    fun tagsFor(annotation: ReaderAnnotation): List<String>

    suspend fun refresh(book: Book)
    suspend fun update(
        book: Book,
        annotation: ReaderAnnotation,
        style: AnnotationStyle? = null,
        colorHex: String? = null,
        note: String? = null,
        tags: List<String>? = null,
    ): ReaderAnnotation

    suspend fun delete(book: Book, annotation: ReaderAnnotation)
}
