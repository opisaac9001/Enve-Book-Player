package com.enve.app.debug

import android.app.Activity
import android.os.Bundle
import androidx.core.net.toUri
import com.enve.app.ui.screens.EbookReaderActivity
import com.enve.core.data.model.BookSource
import com.enve.core.reader.ReaderEngineKind
import java.io.File

class ReaderFixtureActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val filename = intent.getStringExtra("filename") ?: return finish()
        val file = File(getExternalFilesDir(null), filename)
        if (!file.isFile) return finish()
        val engine = intent.getStringExtra("engine")
            ?.let { runCatching { ReaderEngineKind.valueOf(it) }.getOrNull() }
            ?: ReaderEngineKind.READIUM

        startActivity(
            EbookReaderActivity.createIntent(
                context = this,
                bookId = file.toUri().toString(),
                bookSource = BookSource.LOCAL,
                title = "Enve Footnote Fixture",
                author = "Test Fixture",
                bookFormat = "EPUB",
                epubLocator = null,
                epubProgress = 0f,
                readerEngine = engine,
            ).putExtra(EbookReaderActivity.EXTRA_HEARTH_CHROME, true),
        )
        finish()
    }
}
