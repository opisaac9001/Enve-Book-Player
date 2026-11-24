package com.enve.app.data.export

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import com.enve.core.data.model.AnnotationKind
import java.io.OutputStream

object AnnotationPdfRenderer {
    private const val PAGE_WIDTH = 595
    private const val PAGE_HEIGHT = 842
    private const val MARGIN = 54f
    private const val FOOTER_HEIGHT = 24f
    private const val QUOTE_INDENT = 12f
    private val contentWidth = PAGE_WIDTH - 2 * MARGIN
    private val contentBottom = PAGE_HEIGHT - MARGIN - FOOTER_HEIGHT

    fun render(books: List<AnnotationExportBook>, output: OutputStream) {
        val document = PdfDocument()
        try {
            val pager = Pager(document)
            books.forEachIndexed { index, book ->
                val annotations = book.annotations.filter { it.deletedAt == null }.sortedBy { it.createdAt }
                if (index > 0) pager.newPage()
                pager.text(book.title?.takeIf { it.isNotBlank() }?.let(AnnotationExporter::singleLine) ?: "Annotations", titlePaint, 4f)
                val author = book.author?.takeIf { it.isNotBlank() }
                if (author != null) pager.text("by ${AnnotationExporter.singleLine(author)}", authorPaint, 18f) else pager.space(14f)
                val grouped = annotations.groupBy { AnnotationKind.parse(it.kind) }
                AnnotationExporter.kindOrder.forEach { kind ->
                    val list = grouped[kind].orEmpty()
                    if (list.isEmpty()) return@forEach
                    pager.text("${kind.label}s", headingPaint, 10f, keepWithNext = 48f)
                    list.forEach { a ->
                        val bar = parseColor(a.colorHex)
                        if (a.selectedText.isNotBlank()) pager.text(a.selectedText.trim(), quotePaint, 6f, indent = QUOTE_INDENT, barColor = bar)
                        if (a.note.isNotBlank()) pager.text(a.note.trim(), bodyPaint, 6f)
                        val tags = AnnotationExporter.tags(a)
                        if (tags.isNotEmpty()) pager.text(tags.joinToString("  ") { "#$it" }, metaPaint, 3f)
                        pager.text(AnnotationExporter.metaParts(a).joinToString(" · "), metaPaint, 18f)
                    }
                }
            }
            pager.finish()
            document.writeTo(output)
        } finally {
            document.close()
        }
    }

    private class Pager(private val document: PdfDocument) {
        private val barPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private var page: PdfDocument.Page? = null
        private var pageNumber = 0
        private var y = MARGIN

        fun newPage() {
            finishPage()
            ensurePage()
        }

        fun space(points: Float) {
            y += points
        }

        fun text(
            value: String,
            paint: TextPaint,
            spacingAfter: Float,
            indent: Float = 0f,
            barColor: Int? = null,
            keepWithNext: Float = 0f,
        ) {
            val width = (contentWidth - indent).toInt()
            val layout = StaticLayout.Builder.obtain(value, 0, value.length, paint, width)
                .setAlignment(Layout.Alignment.ALIGN_NORMAL)
                .setLineSpacing(0f, 1.2f)
                .setIncludePad(false)
                .build()
            if (page != null && y + minOf(layout.height + keepWithNext, contentBottom - MARGIN) > contentBottom) finishPage()
            var line = 0
            while (line < layout.lineCount) {
                val canvas = ensurePage().canvas
                val top = layout.getLineTop(line)
                var end = line
                while (end < layout.lineCount && y + (layout.getLineBottom(end) - top) <= contentBottom) end++
                if (end == line) {
                    if (y > MARGIN) {
                        finishPage()
                        continue
                    }
                    end = line + 1
                }
                val bottom = layout.getLineBottom(end - 1)
                val height = (bottom - top).toFloat()
                barColor?.let { color ->
                    barPaint.color = color
                    canvas.drawRect(MARGIN, y, MARGIN + 3f, y + height, barPaint)
                }
                draw(canvas, layout, MARGIN + indent, y, top, bottom)
                y += height
                line = end
            }
            y += spacingAfter
        }

        fun finish() {
            ensurePage()
            finishPage()
        }

        private fun draw(canvas: Canvas, layout: StaticLayout, x: Float, y: Float, top: Int, bottom: Int) {
            canvas.save()
            canvas.translate(x, y - top)
            canvas.clipRect(0f, top.toFloat(), layout.width.toFloat(), bottom.toFloat())
            layout.draw(canvas)
            canvas.restore()
        }

        private fun ensurePage(): PdfDocument.Page = page ?: document.startPage(
            PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, ++pageNumber).create(),
        ).also {
            page = it
            y = MARGIN
        }

        private fun finishPage() {
            val current = page ?: return
            val label = pageNumber.toString()
            current.canvas.drawText(label, PAGE_WIDTH - MARGIN - footerPaint.measureText(label), PAGE_HEIGHT - MARGIN, footerPaint)
            document.finishPage(current)
            page = null
        }
    }

    private fun parseColor(hex: String): Int? =
        AnnotationExporter.cssColor(hex).takeIf { it.length == 7 }?.let(Color::parseColor)

    private val titlePaint = textPaint(20f, Typeface.create(Typeface.SERIF, Typeface.BOLD), Color.BLACK)
    private val authorPaint = textPaint(12f, Typeface.create(Typeface.SERIF, Typeface.ITALIC), Color.DKGRAY)
    private val headingPaint = textPaint(14f, Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD), Color.BLACK)
    private val quotePaint = textPaint(11.5f, Typeface.create(Typeface.SERIF, Typeface.ITALIC), Color.rgb(0x33, 0x33, 0x33))
    private val bodyPaint = textPaint(11f, Typeface.SANS_SERIF, Color.BLACK)
    private val metaPaint = textPaint(8.5f, Typeface.SANS_SERIF, Color.GRAY)
    private val footerPaint = textPaint(8f, Typeface.SANS_SERIF, Color.GRAY)

    private fun textPaint(size: Float, typeface: Typeface, color: Int) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = size
        this.typeface = typeface
        this.color = color
    }
}
