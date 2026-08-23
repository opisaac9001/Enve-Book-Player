package com.enve.app.hearth

import com.enve.app.data.repository.AnnotationRepository
import com.enve.app.data.repository.TagIndexStore
import com.enve.app.data.sync.SyncCoordinator
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import com.enve.engine.annotations.AnnotationsFacade
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AnnotationsFacadeImpl @Inject constructor(
    private val annotations: AnnotationRepository,
    private val sync: SyncCoordinator,
    tags: TagIndexStore,
) : AnnotationsFacade {
    override val knownTags: Flow<List<String>> = tags.tagsByUsage

    override fun annotationsForBook(bookId: String): Flow<List<ReaderAnnotation>> =
        annotations.byBook(bookId)

    override fun tagsFor(annotation: ReaderAnnotation): List<String> =
        annotations.tagsFromJson(annotation.tagsJson)

    override suspend fun refresh(book: Book) {
        sync.registerBook(book)
        try {
            sync.pullAnnotations(book)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
        }
        sync.flushAnnotations(book.id)
    }

    override suspend fun update(
        book: Book,
        annotation: ReaderAnnotation,
        style: AnnotationStyle?,
        colorHex: String?,
        note: String?,
        tags: List<String>?,
    ): ReaderAnnotation {
        sync.registerBook(book)
        return annotations.update(
            existing = annotation,
            style = style,
            colorHex = colorHex,
            note = note,
            tags = tags,
        )
    }

    override suspend fun delete(book: Book, annotation: ReaderAnnotation) {
        sync.registerBook(book)
        annotations.delete(annotation.id)
    }
}
