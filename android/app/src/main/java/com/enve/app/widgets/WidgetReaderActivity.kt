package com.enve.app.widgets

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.enve.app.MainActivity
import com.enve.app.ui.screens.ComicReaderActivity
import com.enve.app.ui.screens.EbookReaderActivity
import com.enve.app.ui.screens.PdfReaderActivity

class WidgetReaderActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val readerClass = intent.getStringExtra(EXTRA_READER_CLASS)
        if (readerClass != null && readerClass in setOf(
                EbookReaderActivity::class.java.name,
                PdfReaderActivity::class.java.name,
                ComicReaderActivity::class.java.name,
            )) {
            val readerIntent = Intent().setClassName(this, readerClass)
                .putExtras(intent).apply { removeExtra(EXTRA_READER_CLASS) }
            startActivities(arrayOf(Intent(this, MainActivity::class.java), readerIntent))
        }
        finish()
    }

    companion object {
        internal const val EXTRA_READER_CLASS = "widget_reader_class"
    }
}
