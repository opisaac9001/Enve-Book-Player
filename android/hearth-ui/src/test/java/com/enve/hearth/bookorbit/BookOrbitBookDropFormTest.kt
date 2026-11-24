package com.enve.hearth.bookorbit

import com.enve.engine.bookorbit.BookOrbitBookDropApproval
import com.enve.engine.bookorbit.BookOrbitBookDropFileResult
import com.enve.engine.bookorbit.BookOrbitBookDropItem
import com.enve.engine.bookorbit.BookOrbitBookDropMetadata
import com.enve.engine.bookorbit.BookOrbitBookDropStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BookOrbitBookDropFormTest {
    private fun item(
        status: BookOrbitBookDropStatus = BookOrbitBookDropStatus.READY,
        holdReason: String? = null,
        libraryId: Int? = 4,
        folderId: Int? = 9,
    ) = BookOrbitBookDropItem(
        id = 21,
        fileName = "dune.epub",
        fileSizeBytes = 1_048_576L,
        format = "epub",
        status = status,
        metadata = BookOrbitBookDropMetadata(title = "Dune", authors = listOf("Frank Herbert"), publishedYear = 1965),
        embedded = null,
        fetched = null,
        edited = false,
        targetLibraryId = libraryId,
        targetFolderId = folderId,
        confidence = 92.0,
        errorMessage = null,
        holdReason = holdReason,
        holdLibraryName = "Main",
        formerLibraryName = null,
        alsoIn = emptyList(),
    )

    @Test
    fun untouchedFormProducesNoServerChange() {
        assertNull(BookOrbitBookDropForm(item()).changes(item()))
    }

    @Test
    fun metadataEditLeavesDestinationOutOfTheRequest() {
        val edit = BookOrbitBookDropForm(item()).copy(title = " Dune Messiah ", authors = "Frank Herbert; Brian Herbert, Frank Herbert")
            .changes(item())!!

        assertEquals("Dune Messiah", edit.metadata?.title)
        assertEquals(listOf("Frank Herbert", "Brian Herbert"), edit.metadata?.authors)
        assertEquals(1965, edit.metadata?.publishedYear)
        assertNull(edit.targetLibraryId)
        assertNull(edit.targetFolderId)
    }

    @Test
    fun clearingFetchedFieldsIsSentAsAnEdit() {
        val source = item().let { it.copy(metadata = it.metadata.copy(subtitle = "Book One"), fetched = it.metadata) }
        val edit = BookOrbitBookDropForm(source).copy(title = " ", subtitle = "", authors = "").changes(source)!!

        assertEquals("", edit.metadata?.title)
        assertEquals("", edit.metadata?.subtitle)
        assertEquals(emptyList<String>(), edit.metadata?.authors)
        assertEquals(1965, edit.metadata?.publishedYear)
    }

    @Test
    fun finishedActionOnlyReleasesItsOwnAccountsBusyState() {
        val current = BookOrbitBookDropState(accountId = "account-b", busy = BookOrbitBookDropBusy.SAVING)

        assertEquals(current, current.afterAction("account-a", latest = true))
        assertEquals(current, current.afterAction("account-b", latest = false))
        assertNull(current.afterAction("account-b", latest = true).busy)
    }

    @Test
    fun destinationChangeNeedsBothLibraryAndFolder() {
        val source = item(libraryId = null, folderId = null)
        val libraryOnly = BookOrbitBookDropForm(source).copy(libraryId = 5)
        assertFalse(libraryOnly.hasDestination)
        assertNull(libraryOnly.changes(source))

        val complete = libraryOnly.copy(folderId = 12).changes(source)!!
        assertNull(complete.metadata)
        assertEquals(5, complete.targetLibraryId)
        assertEquals(12, complete.targetFolderId)
    }

    @Test
    fun invalidYearAndSeriesNumberBlockSaving() {
        val form = BookOrbitBookDropForm(item())

        assertTrue(form.valid)
        assertFalse(form.copy(year = "19x5").valid)
        assertFalse(form.copy(year = "65").valid)
        assertTrue(form.copy(year = "").valid)
        assertFalse(form.copy(seriesIndex = "two").valid)
        assertTrue(form.copy(seriesIndex = "2.5").valid)
    }

    @Test
    fun statusLabelsSayWhyAFileWaits() {
        assertEquals("Ready to add", bookDropStatusLabel(item()))
        assertEquals("Needs a destination", bookDropStatusLabel(item(libraryId = null, folderId = null)))
        assertEquals("Already in Main", bookDropStatusLabel(item(holdReason = "duplicate")))
        assertEquals("Waiting for review", bookDropStatusLabel(item(holdReason = "a_future_reason")))
        assertEquals("Failed", bookDropStatusLabel(item(status = BookOrbitBookDropStatus.ERROR)))
        assertTrue(bookDropNeedsAttention(item(holdReason = "duplicate")))
        assertFalse(bookDropNeedsAttention(item()))
    }

    @Test
    fun approvalHeadlineNeverReportsPartialFailureAsSuccess() {
        fun approval(succeeded: Int, failed: Int) = BookOrbitBookDropApproval(
            total = succeeded + failed,
            succeeded = succeeded,
            failed = failed,
            results = List(succeeded) { BookOrbitBookDropFileResult(it, "ok-$it.epub", true, false, null) } +
                List(failed) { BookOrbitBookDropFileResult(100 + it, "bad-$it.epub", false, it == 0, "reason") },
        )

        assertEquals("Added to the library", bookDropApprovalHeadline(approval(1, 0)))
        assertEquals("Added 3 books", bookDropApprovalHeadline(approval(3, 0)))
        assertEquals("Added 1 of 3", bookDropApprovalHeadline(approval(1, 2)))
        assertEquals("Not added", bookDropApprovalHeadline(approval(0, 1)))
        assertEquals("None of the 2 files were added", bookDropApprovalHeadline(approval(0, 2)))
        assertEquals("Nothing was added", bookDropApprovalHeadline(approval(0, 0)))
    }

    @Test
    fun fileSizesAreReadable() {
        assertEquals("512 B", bookDropFileSize(512L))
        assertEquals("2 KB", bookDropFileSize(2_048L))
        assertNull(bookDropFileSize(null))
    }
}
