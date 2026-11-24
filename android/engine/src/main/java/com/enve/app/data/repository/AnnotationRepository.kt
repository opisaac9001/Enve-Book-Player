package com.enve.app.data.repository

import androidx.room.withTransaction
import com.enve.app.data.local.ReaderDatabase
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.sync.AcceptedAnnotation
import kotlinx.coroutines.flow.Flow
import org.json.JSONArray
import org.readium.r2.shared.publication.Locator
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

data class LocatorAnchors(
    val cfi: String? = null,
    val cssSelector: String? = null,
    val textQuoteExact: String? = null,
    val textQuotePrefix: String? = null,
    val textQuoteSuffix: String? = null,
    val progression: Double? = null,
    val totalProgression: Double? = null,
) {
    companion object {
        val EMPTY = LocatorAnchors()

        fun fromReadium(locator: Locator): LocatorAnchors {
            val rawCfi = (
                locator.locations.otherLocations["cfi"] as? String
                    ?: locator.locations.fragments.firstOrNull { it.startsWith("epubcfi(") }
                )
                ?.removePrefix("epubcfi(")
                ?.removeSuffix(")")
            val text = locator.text

            val prefix = text.before?.takeLast(32)?.takeIf { it.isNotBlank() }
            val suffix = text.after?.take(32)?.takeIf { it.isNotBlank() }
            return LocatorAnchors(
                cfi              = rawCfi,
                cssSelector      = locator.locations.otherLocations["cssSelector"] as? String,
                textQuoteExact   = text.highlight?.takeIf { it.isNotBlank() },
                textQuotePrefix  = prefix,
                textQuoteSuffix  = suffix,
                progression      = locator.locations.progression,
                totalProgression = locator.locations.totalProgression,
            )
        }
    }
}

data class AnnotationScope(val bookId: String, val connectionId: String?)

val Book.annotationScope: AnnotationScope get() = AnnotationScope(id, connectionId)

@Singleton
class AnnotationRepository @Inject constructor(
    private val db: ReaderDatabase,
) {
    private val dao = db.annotationDao()

    @Volatile
    private var primaryChangeListener: ((AnnotationScope) -> Unit)? = null

    fun setChangeListener(listener: ((AnnotationScope) -> Unit)?) {
        primaryChangeListener = listener
    }

    fun byBook(bookId: String, connectionId: String?): Flow<List<ReaderAnnotation>> =
        dao.flowByBook(bookId, connectionId)
    fun byBookAndKind(bookId: String, connectionId: String?, kind: AnnotationKind): Flow<List<ReaderAnnotation>> =
        dao.flowByBookAndKind(bookId, connectionId, kind.name)

    fun all(): Flow<List<ReaderAnnotation>> = dao.flowAll()
    fun search(query: String): Flow<List<ReaderAnnotation>> = dao.search("%$query%")

    suspend fun forBook(bookId: String, connectionId: String?): List<ReaderAnnotation> = dao.getByBook(bookId, connectionId)
    suspend fun byId(id: String): ReaderAnnotation? = dao.getById(id)
    suspend fun dirty(): List<ReaderAnnotation> = dao.getDirty()
    suspend fun dirtyFor(scope: AnnotationScope): List<ReaderAnnotation> =
        dao.getDirtyForBook(scope.bookId, scope.connectionId)

    suspend fun create(
        bookId: String,
        connectionId: String?,
        kind: AnnotationKind,
        media: AnnotationMedia,
        style: AnnotationStyle = AnnotationStyle.HIGHLIGHT,
        colorHex: String = "#FFF59D",
        locatorJson: String? = null,
        pdfPage: Int? = null,
        pdfRectsJson: String? = null,
        cbzPage: Int? = null,
        audioPositionMs: Long? = null,
        chapterId: String? = null,
        selectedText: String = "",
        note: String = "",
        tags: List<String> = emptyList(),
        attachmentUriString: String? = null,
        attachmentKind: String? = null,
        anchors: LocatorAnchors = LocatorAnchors.EMPTY,
        providerSource: String = "local",
    ): ReaderAnnotation {
        val now = System.currentTimeMillis()
        val a = ReaderAnnotation(
            id = UUID.randomUUID().toString(),
            bookId = bookId,
            kind = kind.name,
            media = media.name,
            style = if (kind == AnnotationKind.HIGHLIGHT) style.name else AnnotationStyle.NONE.name,
            colorHex = colorHex,
            locatorJson = locatorJson,
            pdfPage = pdfPage,
            pdfRectsJson = pdfRectsJson,
            cbzPage = cbzPage,
            audioPositionMs = audioPositionMs,
            chapterId = chapterId,
            selectedText = selectedText,
            note = note,
            tagsJson = tagsToJson(tags),
            attachmentUriString = attachmentUriString,
            attachmentKind = attachmentKind,
            cfi = anchors.cfi,
            cssSelector = anchors.cssSelector,
            textQuoteExact = anchors.textQuoteExact,
            textQuotePrefix = anchors.textQuotePrefix,
            textQuoteSuffix = anchors.textQuoteSuffix,
            progression = anchors.progression,
            totalProgression = anchors.totalProgression,
            createdAt = now,
            updatedAt = now,
            providerSource = providerSource,
            syncDirty = true,
            connectionId = connectionId,
        )
        dao.upsert(a)
        notifyChanged(a)
        return a
    }

    suspend fun update(
        existing: ReaderAnnotation,
        style: AnnotationStyle? = null,
        colorHex: String? = null,
        note: String? = null,
        tags: List<String>? = null,
    ): ReaderAnnotation {
        val now = System.currentTimeMillis()
        val updated = db.withTransaction {
            val current = dao.getById(existing.id) ?: existing
            current.copy(
                style = style?.name ?: current.style,
                colorHex = colorHex ?: current.colorHex,
                note = note ?: current.note,
                tagsJson = tags?.let(::tagsToJson) ?: current.tagsJson,
                updatedAt = now,
                syncDirty = true,
            ).also { dao.upsert(it) }
        }
        notifyChanged(updated)
        return updated
    }

    suspend fun delete(id: String) {
        val existing = dao.getById(id) ?: return
        dao.softDelete(id)
        notifyChanged(existing)
    }

    suspend fun restore(id: String) {
        val existing = dao.getById(id) ?: return
        dao.restore(id)
        notifyChanged(existing)
    }

    suspend fun purge(id: String) {
        val existing = dao.getById(id) ?: return
        dao.purge(id)
        notifyChanged(existing)
    }

    suspend fun applyRemote(scope: AnnotationScope, remotes: List<ReaderAnnotation>) {
        if (remotes.isEmpty()) return
        dao.reconcileRemote(remotes.map { it.owned(scope) })
        notifyChanged(scope)
    }

    suspend fun applyAuthoritativeRemote(
        scope: AnnotationScope,
        providerSource: String,
        remotes: List<ReaderAnnotation>,
    ) {
        dao.reconcileAuthoritativeRemote(scope.bookId, scope.connectionId, providerSource, remotes.map { it.owned(scope) })
        notifyChanged(scope)
    }

    private fun ReaderAnnotation.owned(scope: AnnotationScope) =
        copy(connectionId = scope.connectionId, connectionUnresolved = false)

    suspend fun acknowledgePushed(sent: List<ReaderAnnotation>, accepted: List<AcceptedAnnotation>) {
        if (accepted.isEmpty()) return
        dao.acknowledgePushed(sent, accepted)
    }

    private fun tagsToJson(tags: List<String>): String {
        if (tags.isEmpty()) return "[]"
        val arr = JSONArray()
        tags.forEach { arr.put(it) }
        return arr.toString()
    }

    fun tagsFromJson(json: String?): List<String> {
        if (json.isNullOrBlank()) return emptyList()
        return runCatching {
            val arr = JSONArray(json)
            buildList {
                for (i in 0 until arr.length()) {
                    arr.optString(i).takeIf { it.isNotBlank() }?.let(::add)
                }
            }
        }.getOrDefault(emptyList())
    }

    private fun notifyChanged(annotation: ReaderAnnotation) {
        if (!annotation.connectionUnresolved) notifyChanged(AnnotationScope(annotation.bookId, annotation.connectionId))
    }

    private fun notifyChanged(scope: AnnotationScope) {
        primaryChangeListener?.invoke(scope)
    }
}
