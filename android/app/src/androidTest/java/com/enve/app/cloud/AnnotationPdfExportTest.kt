package com.enve.app.cloud

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import androidx.core.content.FileProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.export.AnnotationExportBook
import com.enve.app.data.export.AnnotationPdfRenderer
import com.enve.core.data.model.ReaderAnnotation
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AnnotationPdfExportTest {
    @Test
    fun paginatesUnicodeAnnotationsAndSharesOnlyTheExportDirectory() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val file = File(context.cacheDir, "annotation-exports/pdf-test-${System.nanoTime()}.pdf")
        file.parentFile!!.mkdirs()
        try {
            val annotations = List(60) { index ->
                ReaderAnnotation(
                    id = "pdf-$index", bookId = "fixture", selectedText = "A chapter in the reading life. Café, 日本語, العربية. ".repeat(5),
                    note = "Reader note $index", pdfPage = index, media = "PDF",
                )
            }
            file.outputStream().use { AnnotationPdfRenderer.render(listOf(AnnotationExportBook("Export fixture", "Enve test", annotations)), it) }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            assertEquals("content", uri.scheme)
            context.contentResolver.openFileDescriptor(uri, "r")!!.use { descriptor ->
                PdfRenderer(descriptor).use { renderer ->
                    assertTrue(renderer.pageCount > 1)
                    renderer.openPage(renderer.pageCount - 1).use { page ->
                        val bitmap = Bitmap.createBitmap(page.width, page.height, Bitmap.Config.ARGB_8888)
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        val pixels = IntArray(bitmap.width * bitmap.height)
                        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                        assertTrue(pixels.count { Color.red(it) < 200 && Color.alpha(it) > 0 } > 100)
                        bitmap.recycle()
                    }
                }
            }
        } finally {
            file.delete()
        }
    }
}
