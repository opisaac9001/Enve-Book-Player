package com.enve.app.data.readwise

import com.enve.core.data.model.ReaderAnnotation

internal data class ReadwisePendingHighlight(
    val annotationId: String,
    val bookId: String,
    val fingerprint: String,
    val payload: ReadwiseHighlightPayload,
    val remoteId: Long?,
) {
    val changed: Boolean get() = remoteId != null
}

internal data class ReadwiseExportPlan(
    val pending: List<ReadwisePendingHighlight>,
    val alreadySentCount: Int,
    val excludedCount: Int,
    val oversizedCount: Int,
) {
    val bookCount: Int get() = pending.distinctBy { it.bookId }.size
}

internal object ReadwiseExportPlanner {
    fun plan(
        annotations: List<ReaderAnnotation>,
        books: (ReaderAnnotation) -> ReadwiseBookInfo?,
        receipts: Map<String, ReadwiseReceipt>,
    ): ReadwiseExportPlan {
        val (exportable, excluded) = annotations.partition(ReadwiseHighlightMapper::isExportable)
        val pending = mutableListOf<ReadwisePendingHighlight>()
        var alreadySent = 0
        var oversized = 0
        exportable
            .sortedWith(compareBy<ReaderAnnotation>({ it.bookId }, { it.createdAt }, { it.id }))
            .forEach { annotation ->
                val payload = ReadwiseHighlightMapper.payload(annotation, books(annotation))
                if (!ReadwiseHighlightMapper.fitsLimits(payload)) {
                    oversized++
                    return@forEach
                }
                val fingerprint = ReadwiseHighlightMapper.fingerprint(payload)
                val receipt = receipts[annotation.id]
                if (receipt?.fingerprint == fingerprint) {
                    alreadySent++
                } else {
                    pending += ReadwisePendingHighlight(
                        annotationId = annotation.id,
                        bookId = annotation.bookId,
                        fingerprint = fingerprint,
                        payload = payload,
                        remoteId = receipt?.remoteId,
                    )
                }
            }
        return ReadwiseExportPlan(pending, alreadySent, excluded.size, oversized)
    }
}
