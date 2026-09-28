package com.enve.app.data.opds

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.local.ReaderDatabase
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OpdsProgressionStateStoreTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private val ebookId = "https://opds.example.com/moby.epub"
    private val audiobookId = "urn:uuid:019c0049-6e8c-745c-adb1-5b03f8ad50c4"
    private val noMembers = JsonObject(emptyMap())
    private val vendorMembers = Json.parseToJsonElement("""{"x-shelf":{"seat":2}}""") as JsonObject

    @Before
    fun setUp() {
        context.deleteDatabase(DB_NAME)
    }

    @After
    fun tearDown() {
        context.deleteDatabase(DB_NAME)
    }

    @Test
    fun unhandled_references_survive_a_restart_for_ebooks_and_audiobooks() = runBlocking {
        val first = open()
        OpdsProgressionStateStore(first.opdsProgressionStateDao()).apply {
            save("conn-1", ebookId, listOf("#xywh=160,120,320,240", "vendor:state=later"), noMembers)
            save("conn-1", audiobookId, listOf("#custom=part-4"), vendorMembers)
        }
        first.close()

        val second = open()
        val store = OpdsProgressionStateStore(second.opdsProgressionStateDao())

        assertEquals(
            listOf("#xywh=160,120,320,240", "vendor:state=later"),
            store.carryover("conn-1", ebookId).references,
        )
        assertEquals(listOf("#custom=part-4"), store.carryover("conn-1", audiobookId).references)
        assertEquals(vendorMembers, store.carryover("conn-1", audiobookId).additionalMembers)
        second.close()
    }

    @Test
    fun the_last_authoritative_document_replaces_what_was_stored() = runBlocking {
        val first = open()
        OpdsProgressionStateStore(first.opdsProgressionStateDao())
            .save("conn-1", ebookId, listOf("#xywh=1,2,3,4"), noMembers)
        first.close()

        val second = open()
        OpdsProgressionStateStore(second.opdsProgressionStateDao())
            .save("conn-1", ebookId, listOf("#custom=newer"), noMembers)
        second.close()

        val third = open()
        assertEquals(
            listOf("#custom=newer"),
            OpdsProgressionStateStore(third.opdsProgressionStateDao()).carryover("conn-1", ebookId).references,
        )
        third.close()
    }

    private fun open(): ReaderDatabase =
        Room.databaseBuilder(context, ReaderDatabase::class.java, DB_NAME).build()

    private companion object {
        const val DB_NAME = "opds-progression-state-test.db"
    }
}
