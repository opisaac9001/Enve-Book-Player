package com.enve.app.cloud

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.automation.ReaderShortcuts
import com.enve.app.data.fileimport.ImportPlanner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class IncomingBookIntentTest {
    private val ownAuthority = "com.enve.app.debug.fileprovider"
    private val book = Uri.parse("content://com.android.providers.downloads.documents/document/41")

    @Test
    fun acceptsViewAndShareWithoutAcceptingRemoteOrPrivateUris() {
        for (action in listOf(Intent.ACTION_VIEW, Intent.ACTION_SEND)) {
            val intent = Intent(action).setData(book).putExtra(Intent.EXTRA_STREAM, book)
            assertEquals(listOf(book), IncomingBookIntent.files(intent, ownAuthority))
        }
        for (uri in listOf("https://example.org/book.epub", "file:///data/private/book.epub", "content://$ownAuthority/book.epub")) {
            assertTrue(IncomingBookIntent.files(Intent(Intent.ACTION_VIEW, Uri.parse(uri)), ownAuthority).isEmpty())
        }
        assertTrue(IncomingBookIntent.files(Intent(Intent.ACTION_MAIN, book), ownAuthority).isEmpty())
    }

    @Test
    fun multiShareDeduplicatesAndCapsSelectionWithOverflowSentinel() {
        val items = ArrayList((0..ImportPlanner.MAX_FILES + 5).map { Uri.parse("content://books/$it") })
        items.add(0, items.first())
        val intent = Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, items)
        val files = IncomingBookIntent.files(intent, ownAuthority)
        assertEquals(ImportPlanner.MAX_FILES + 1, files.size)
        assertEquals(files.size, files.distinct().size)
    }

    @Test
    fun acceptsClipDataFromShareButNotAnUnrelatedIntent() {
        val intent = Intent(Intent.ACTION_SEND).apply { clipData = ClipData.newRawUri("book", book) }
        assertEquals(listOf(book), IncomingBookIntent.files(intent, ownAuthority))
        intent.action = Intent.ACTION_MAIN
        assertTrue(IncomingBookIntent.files(intent, ownAuthority).isEmpty())
    }

    @Test
    fun shortcutActionsAreExplicitAndHaveNoBookMetadata() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        assertEquals(ReaderShortcuts.CONTINUE, ReaderShortcuts.request(context, Intent("${context.packageName}.${ReaderShortcuts.CONTINUE}")))
        assertNull(ReaderShortcuts.request(context, Intent(Intent.ACTION_VIEW, book)))
    }
}
