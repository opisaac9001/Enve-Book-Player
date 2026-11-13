package com.enve.silo

import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.ReaderAnnotation
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SiloAnnotationSyncTest {
    private val etagA = "\"aaaa\""
    private val etagB = "\"bbbb\""
    private val etagC = "\"cccc\""
    private val older = 1_767_323_045_000L
    private val newer = older + 60_000L

    private fun record(id: String, etag: String, updatedAt: String = "2026-01-02T03:04:05.000Z", note: String = "remote") =
        """{"id":"$id","content_id":"book","kind":"note","cfi_range":"epubcfi(/6/2!/4/2:1)","location":"epubcfi(/6/2!/4/2:1)","selected_text":"","note":"$note","style":"highlight","color":"#facc15","metadata":{"enve_local_id":"$id","enve_position":"0.5","other":3},"created_at":"$updatedAt","updated_at":"$updatedAt","etag":${quoted(etag)}}"""

    private fun quoted(value: String) = "\"" + value.replace("\"", "\\\"") + "\""

    private fun local(
        id: String = "local-1",
        serverId: String? = null,
        etag: String? = null,
        updatedAt: Long = newer,
        deletedAt: Long? = null,
        kind: String = AnnotationKind.NOTE.name,
        cfi: String? = "epubcfi(/6/2!/4/2:1)",
    ) = ReaderAnnotation(
        id = id,
        bookId = "book",
        kind = kind,
        cfi = cfi,
        totalProgression = 0.5,
        note = "mine",
        updatedAt = updatedAt,
        deletedAt = deletedAt,
        serverId = serverId,
        syncEtag = etag,
    )

    @Test
    fun newAnnotationIsCreatedWithItsClientIdentity() = runBlocking {
        val transport = SiloFakeTransport { SiloReply(201, record("local-1", etagA)) }
        val result = SiloAnnotationSync(transport.api, "profile-1", "book").push(listOf(local()))
        val call = transport.calls.single()
        assertEquals("POST", call.method)
        assertEquals("/api/v2/ebooks/book/annotations", call.path)
        assertEquals("local-1", call.json()["id"]!!.jsonPrimitive.content)
        assertEquals("local-1", call.json()["metadata"]!!.jsonObject["enve_local_id"]!!.jsonPrimitive.content)
        assertEquals(etagA, result.accepted.single().etag)
        assertEquals("local-1", result.accepted.single().serverId)
    }

    @Test
    fun bookmarkWithoutCfiOmitsCfiRangeOnCreate() = runBlocking {
        val transport = SiloFakeTransport { SiloReply(201, record("local-1", etagA)) }
        SiloAnnotationSync(transport.api, "profile-1", "book")
            .push(listOf(local(kind = AnnotationKind.BOOKMARK.name, cfi = null)))
        val body = transport.calls.single().json()
        assertFalse("cfi_range" in body)
        assertEquals("bookmark", body["kind"]!!.jsonPrimitive.content)
        assertEquals("fraction:0.500000", body["location"]!!.jsonPrimitive.content)
    }

    @Test
    fun editIsGuardedByTheStoredEtag() = runBlocking {
        val transport = SiloFakeTransport { SiloReply(200, record("local-1", etagB)) }
        val result = SiloAnnotationSync(transport.api, "profile-1", "book")
            .push(listOf(local(serverId = "local-1", etag = etagA)))
        val call = transport.calls.single()
        assertEquals("PATCH", call.method)
        assertEquals("/api/v2/ebooks/book/annotations/local-1", call.path)
        assertEquals(etagA, call.headers["If-Match"])
        assertEquals(etagB, result.accepted.single().etag)
    }

    @Test
    fun staleEtagWithNewerRemoteEditReturnsAConflictWithoutOverwriting() = runBlocking {
        val transport = SiloFakeTransport { call ->
            when (call.method) {
                "PATCH" -> problem("precondition_failed", 412)
                else -> if (call.query("cursor") == null) {
                    SiloReply(200, """{"items":[],"page":{"next_cursor":"p2","has_more":true}}""")
                } else {
                    SiloReply(200, """{"items":[${record("local-1", etagC, "2026-01-05T00:00:00.000Z")}],"page":{"has_more":false}}""")
                }
            }
        }
        val result = SiloAnnotationSync(transport.api, "profile-1", "book")
            .push(listOf(local(serverId = "local-1", etag = etagA, updatedAt = newer)))
        assertTrue(result.accepted.isEmpty())
        assertTrue(result.rejected.isEmpty())
        val conflict = result.conflicts.single()
        assertEquals(etagC, conflict.syncEtag)
        assertFalse(conflict.syncDirty)
        assertEquals(1, transport.calls.count { it.method == "PATCH" })
    }

    @Test
    fun staleEtagConflictsEvenWhenTheLocalClockIsAhead() = runBlocking {
        var patches = 0
        val transport = SiloFakeTransport { call ->
            when (call.method) {
                "PATCH" -> if (patches++ == 0) problem("precondition_failed", 412) else SiloReply(200, record("local-1", etagC))
                else -> SiloReply(200, """{"items":[${record("local-1", etagB)}]}""")
            }
        }
        val result = SiloAnnotationSync(transport.api, "profile-1", "book")
            .push(listOf(local(serverId = "local-1", etag = etagA, updatedAt = newer)))
        val patchCalls = transport.calls.filter { it.method == "PATCH" }
        assertEquals(listOf(etagA), patchCalls.map { it.headers["If-Match"] })
        assertTrue(result.accepted.isEmpty())
        assertEquals(etagB, result.conflicts.single().syncEtag)
    }

    @Test
    fun legacyTimestampCannotAuthorizeAnOverwrite() = runBlocking {
        val transport = SiloFakeTransport { call ->
            when (call.method) {
                "PATCH" -> SiloReply(200, record("server-9", etagC))
                else -> SiloReply(200, """{"items":[${record("server-9", etagB)}]}""")
            }
        }
        val result = SiloAnnotationSync(transport.api, "profile-1", "book")
            .push(listOf(local(serverId = "server-9", etag = "2026-01-01T00:00:00Z", updatedAt = newer)))
        assertTrue(transport.calls.none { it.method == "PATCH" })
        assertTrue(result.accepted.isEmpty())
        assertEquals("server-9", result.conflicts.single().serverId)
    }

    @Test
    fun legacyEtagWithNewerRemoteIsAConflict() = runBlocking {
        val transport = SiloFakeTransport { SiloReply(200, """{"items":[${record("server-9", etagB, "2026-01-05T00:00:00.000Z")}]}""") }
        val result = SiloAnnotationSync(transport.api, "profile-1", "book")
            .push(listOf(local(serverId = "server-9", etag = null, updatedAt = newer)))
        assertEquals(etagB, result.conflicts.single().syncEtag)
        assertTrue(transport.calls.none { it.method == "PATCH" })
    }

    @Test
    fun editOfARemotelyDeletedAnnotationRemainsPending() = runBlocking {
        val transport = SiloFakeTransport { call ->
            when (call.method) {
                "PATCH" -> problem("not_found", 404)
                else -> SiloReply(201, record("local-1", etagA))
            }
        }
        val result = SiloAnnotationSync(transport.api, "profile-1", "book")
            .push(listOf(local(serverId = "old", etag = etagB)))
        assertEquals(listOf("PATCH"), transport.calls.map { it.method })
        assertTrue(result.accepted.isEmpty())
        assertEquals("local-1", result.rejected.single().id)
    }

    @Test
    fun retriedCreateCannotOverwriteAnotherVersion() = runBlocking {
        val transport = SiloFakeTransport { call ->
            when (call.method) {
                "POST" -> SiloReply(200, record("local-1", etagA, note = "older"))
                else -> SiloReply(200, record("local-1", etagB, note = "mine"))
            }
        }
        val result = SiloAnnotationSync(transport.api, "profile-1", "book").push(listOf(local()))
        assertEquals(listOf("POST"), transport.calls.map { it.method })
        assertTrue(result.accepted.isEmpty())
        assertEquals(etagA, result.conflicts.single().syncEtag)
    }

    @Test
    fun deleteIsGuardedAndMissingIsAccepted() = runBlocking {
        val transport = SiloFakeTransport { call -> if (call.path.endsWith("/gone")) problem("not_found", 404) else SiloReply(204) }
        val result = SiloAnnotationSync(transport.api, "profile-1", "book").push(
            listOf(
                local(id = "a", serverId = "kept", etag = etagA, deletedAt = newer),
                local(id = "b", serverId = "gone", etag = etagA, deletedAt = newer),
                local(id = "c", serverId = null, deletedAt = newer),
            ),
        )
        assertEquals(listOf("a", "b", "c"), result.accepted.map { it.id })
        assertEquals(2, transport.calls.size)
        assertTrue(transport.calls.all { it.method == "DELETE" && it.headers["If-Match"] == etagA })
    }

    @Test
    fun deleteAgainstANewerRemoteEditIsAConflict() = runBlocking {
        val transport = SiloFakeTransport { call ->
            when (call.method) {
                "DELETE" -> problem("precondition_failed", 412)
                else -> SiloReply(200, """{"items":[${record("kept", etagB, "2026-01-05T00:00:00.000Z")}]}""")
            }
        }
        val result = SiloAnnotationSync(transport.api, "profile-1", "book")
            .push(listOf(local(id = "a", serverId = "kept", etag = etagA, deletedAt = newer, updatedAt = newer)))
        assertTrue(result.accepted.isEmpty())
        assertEquals(1, result.conflicts.size)
    }

    @Test
    fun serverFailuresStayRejectedSoLocalEditsRemainDirty() = runBlocking {
        val transport = SiloFakeTransport { problem("dependency_unavailable", 503) }
        val result = SiloAnnotationSync(transport.api, "profile-1", "book")
            .push(listOf(local(serverId = "local-1", etag = etagA)))
        assertTrue(result.accepted.isEmpty())
        assertEquals("HTTP 503 dependency_unavailable", result.rejected.single().reason)
    }

    @Test
    fun pullFollowsCursorsAndKeepsEtagsAndLocalIdentity() = runBlocking {
        val transport = SiloFakeTransport { call ->
            if (call.query("cursor") == null) {
                SiloReply(200, """{"items":[${record("local-1", etagA)}],"page":{"next_cursor":"n","has_more":true}}""")
            } else {
                SiloReply(200, """{"items":[${record("local-2", etagB)}],"page":{"has_more":false}}""")
            }
        }
        val pulled = SiloAnnotationSync(transport.api, "profile-1", "book").records().map { it.toReaderAnnotation("book") }
        assertEquals(listOf("local-1", "local-2"), pulled.map { it.id })
        assertEquals(listOf(etagA, etagB), pulled.map { it.syncEtag })
        assertEquals("50", transport.calls.first().query("limit"))
        assertEquals(older, pulled.first().updatedAt)
    }


    @Test
    fun deleteWithAStaleGuardCannotUseClockOrderToOverwrite() = runBlocking {
        for (remoteTime in listOf(older, newer)) {
            val transport = SiloFakeTransport { call ->
                if (call.method == "DELETE") problem("precondition_failed", 412)
                else SiloReply(200, """{"items":[${record("kept", etagB, siloInstant(remoteTime))}]}""")
            }
            val result = SiloAnnotationSync(transport.api, "profile-1", "book")
                .push(listOf(local(serverId = "kept", etag = etagA, deletedAt = newer)))
            assertTrue(result.accepted.isEmpty())
            assertEquals(1, result.conflicts.size)
            assertEquals(1, transport.calls.count { it.method == "DELETE" })
        }
    }

    @Test
    fun missingEbookPullsNothing() = runBlocking {
        val transport = SiloFakeTransport { problem("not_found", 404) }
        assertTrue(SiloAnnotationSync(transport.api, "profile-1", "book").records().isEmpty())
    }
}
