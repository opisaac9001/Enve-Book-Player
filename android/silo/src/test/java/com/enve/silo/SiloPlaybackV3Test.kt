package com.enve.silo

import com.enve.silo.dto.SiloPlaybackCapabilitiesDto
import com.enve.silo.dto.SiloPlaybackMutationDto
import com.enve.silo.dto.SiloPlaybackProgressRequest
import com.enve.silo.dto.SiloPlaybackStartRequest
import com.enve.silo.dto.SiloPlaybackStartResponse
import com.enve.silo.dto.SiloPlaybackStopRequest
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.Response

class SiloPlaybackV3Test {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val installation = "11111111-1111-4111-8111-111111111111"
    private val session = "22222222-2222-4222-8222-222222222222"

    @Test fun multipartStartSendsInstallationStringFileIdAndClientProgressOwnership() = runBlocking {
        val transport = SiloFakeTransport { SiloReply(201, PLAYABLE) }
        transport.api.startPlayback(
            "profile-1",
            SiloPlaybackStartRequest(
                installationId = installation,
                fileId = "42",
                profileId = "profile-1",
                playbackAttemptId = "attempt-00000001",
                progressPersistence = "client",
                startPosition = 0.0,
            ),
        )
        val call = transport.calls.single()
        val body = call.json()
        assertEquals("POST", call.method)
        assertEquals("/api/v2/playback/start", call.path)
        assertEquals("profile-1", call.headers["X-Profile-Id"])
        assertEquals(installation, body["installation_id"]!!.jsonPrimitive.content)
        assertEquals("\"42\"", body["file_id"].toString())
        assertEquals("client", body["progress_persistence"]!!.jsonPrimitive.content)
        assertEquals("auto", body["quality_preference"]!!.jsonPrimitive.content)
        assertEquals("0.0", body["start_position"].toString())
        val capabilities = body["client_capabilities"]!!.jsonObject
        assertEquals("[]", capabilities["codecs_video"].toString())
        assertEquals("[]", capabilities["codecs_video_hardware"].toString())
        val context = body["client_playback_context"]!!.jsonObject
        assertTrue(context["app_version"] is JsonPrimitive)
        assertEquals("{}", context["output"].toString())
        val delivery = context["deliveries"]!!.jsonObject["original_http"]!!.jsonObject
        assertEquals("[]", delivery["video_codecs"].toString())

    }

    @Test fun serverResumeStartOmitsStartPositionInsteadOfSendingNull() = runBlocking {
        val transport = SiloFakeTransport { SiloReply(201, PLAYABLE) }
        transport.api.startPlayback(
            "profile-1",
            SiloPlaybackStartRequest(installationId = installation, fileId = "42", profileId = "profile-1", playbackAttemptId = "attempt-00000002"),
        )
        assertFalse("start_position" in transport.calls.single().json())
    }

    @Test fun playableAndTerminalDecisionsAreDistinct() {
        val playable = json.decodeFromString<SiloPlaybackStartResponse>(PLAYABLE)
        assertEquals(session, playable.audioPlan().first)
        assertEquals("/api/v2/stream/$session", playable.audioPlan().second.stream.url)
        assertEquals(12.5, playable.audioPlan().second.timeline.sourceStartSeconds, 0.0)

        val terminal = json.decodeFromString<SiloPlaybackStartResponse>(
            """{"protocol_version":3,"outcome":"adaptation_unavailable","terminal":{"reason":"audio_unsupported"}}""",
        )
        assertThrows(IllegalStateException::class.java) { terminal.audioPlan() }
    }

    @Test fun progressSampleCarriesInstallationAndSequence() = runBlocking {
        val transport = SiloFakeTransport { SiloReply(200, """{"outcome":"applied","accepted":{"sequence":7,"position":120,"is_paused":true}}""") }
        val outcome = transport.api.updatePlaybackProgress("profile-1", session, SiloPlaybackProgressRequest(installation, 7, 120.0, true))
            .sampleOutcome(7, 7)
        val call = transport.calls.single()
        assertEquals("/api/v2/playback/$session/progress", call.path)
        assertEquals(setOf("installation_id", "sequence", "position", "is_paused"), call.json().keys)
        assertEquals("7", call.json()["sequence"].toString())
        assertEquals(SiloSampleOutcome.APPLIED, outcome)
    }

    @Test fun replayedSampleIsApplied() {
        assertEquals(SiloSampleOutcome.APPLIED, mutation(200, """{"outcome":"replayed","accepted":{"sequence":3,"position":5}}""").sampleOutcome(3, 3))
    }

    @Test fun staleSampleIsAcceptedOnlyWhenOurOwnNewerSampleWon() {
        val stale = """{"outcome":"stale_sample","accepted":{"sequence":42,"position":120,"is_paused":false}}"""
        assertEquals(SiloSampleOutcome.APPLIED, mutation(200, stale).sampleOutcome(41, 42))
        assertThrows(IllegalStateException::class.java) { mutation(200, stale).sampleOutcome(41, 41) }
        assertThrows(IllegalStateException::class.java) {
            mutation(200, """{"outcome":"stale_sample"}""").sampleOutcome(1, 1)
        }
    }

    @Test fun lostSessionsAndInstallationChangesAreDistinguishedFromConflicts() {
        assertEquals(SiloSampleOutcome.SESSION_GONE, mutation(problem("not_found", 404)).sampleOutcome(1, 1))
        assertEquals(SiloSampleOutcome.SESSION_GONE, mutation(problem("playback_session_ended", 410)).sampleOutcome(1, 1))
        assertEquals(SiloSampleOutcome.INSTALLATION_CHANGED, mutation(problem("installation_changed", 409)).sampleOutcome(1, 1))
        assertThrows(IllegalStateException::class.java) { mutation(problem("progress_conflict", 409)).sampleOutcome(1, 1) }
        assertThrows(IllegalStateException::class.java) { mutation(problem("dependency_unavailable", 503)).sampleOutcome(1, 1) }
        assertThrows(IllegalStateException::class.java) { mutation(200, """{"outcome":"something_new"}""").sampleOutcome(1, 1) }
    }

    @Test fun stopIsADeleteWithAStopIdentityBody() = runBlocking {
        val transport = SiloFakeTransport { SiloReply(200, """{"outcome":"stopped","stop_id":"44444444-4444-4444-8444-444444444444"}""") }
        transport.api.stopPlayback("profile-1", session, SiloPlaybackStopRequest(installation, "44444444-4444-4444-8444-444444444444"))
        val call = transport.calls.single()
        assertEquals("DELETE", call.method)
        assertEquals("/api/v2/playback/$session", call.path)
        assertEquals(setOf("installation_id", "stop_id"), call.json().keys)
    }

    @Test fun installationIsFetchedOncePerConnectionAndRefetchedAfterForget() = runBlocking {
        val transport = SiloFakeTransport { SiloReply(200, CAPABILITIES) }
        val installations = SiloPlaybackInstallations(transport.api)
        assertEquals(installation, installations.current("connection-a", "profile-1"))
        assertEquals(installation, installations.current("connection-a", "profile-1"))
        assertEquals(1, transport.calls.size)
        assertEquals("/api/v2/playback/capabilities", transport.calls.single().path)
        assertEquals("profile-1", transport.calls.single().headers["X-Profile-Id"])
        installations.forget("connection-a")
        installations.current("connection-a", "profile-1")
        installations.current("connection-b", "profile-1")
        assertEquals(3, transport.calls.size)
    }

    @Test fun unusableCapabilitiesAreRefused() {
        val available = json.decodeFromString<SiloPlaybackCapabilitiesDto>(CAPABILITIES)
        assertEquals(installation, available.installation())
        assertThrows(IllegalStateException::class.java) { available.copy(state = "not_configured").installation() }
        assertThrows(IllegalStateException::class.java) { available.copy(allowed = false).installation() }
        assertThrows(IllegalStateException::class.java) { available.copy(features = listOf("playback_plan_v3")).installation() }
        assertThrows(IllegalStateException::class.java) { available.copy(installationId = null).installation() }
        assertTrue(SILO_SEQUENCED_PROGRESS in available.features)
    }

    private fun mutation(code: Int, body: String): Response<SiloPlaybackMutationDto> = runBlocking {
        SiloFakeTransport { SiloReply(code, body) }.api
            .updatePlaybackProgress("profile-1", session, SiloPlaybackProgressRequest(installation, 1, 0.0, false))
    }

    private fun mutation(reply: SiloReply): Response<SiloPlaybackMutationDto> = mutation(reply.code, reply.body)

    private companion object {
        const val PLAYABLE = """{"protocol_version":3,"server_features":["sequenced_progress_v1"],"outcome":"playable","session_id":"22222222-2222-4222-8222-222222222222","playback_plan":{"protocol_version":3,"plan_id":"plan:1","plan_attempt_key":"v3:1","delivery":"original_http","stream":{"url":"/api/v2/stream/22222222-2222-4222-8222-222222222222","protocol":"http_progressive"},"timeline":{"source_start_seconds":12.5,"player_start_seconds":12.5,"timeline_offset_seconds":0},"source":{"media_file_id":"42","duration_seconds":90},"requested_media_file_id":"42","effective_media_file_id":"42"}}"""
        const val CAPABILITIES = """{"revision":"r","state":"available","allowed":true,"installation_id":"11111111-1111-4111-8111-111111111111","protocol_versions":[3],"features":["playback_plan_v3","sequenced_progress_v1"],"deliveries":["original_http"]}"""
    }
}
