package com.enve.silo

import com.enve.silo.dto.SiloPlaybackStartRequest
import com.enve.silo.dto.SiloPlaybackStartResponse
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SiloPlaybackV3Test {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Test fun multipartStartDeclaresClientProgressOwnership() {
        val request = SiloPlaybackStartRequest(
            fileId = 42,
            profileId = "profile-1",
            playbackAttemptId = "attempt-00000001",
            progressPersistence = "client",
            startPosition = 0.0,
        )
        val encoded = json.encodeToString(request)
        assertTrue(encoded.contains("\"protocol_version\":3"))
        assertTrue(encoded.contains("\"audio_evidence\":\"declared\""))
        assertTrue(encoded.contains("\"original_http\""))
        assertTrue(encoded.contains("\"progress_persistence\":\"client\""))
        assertTrue(encoded.contains("\"start_position\":0.0"))
    }

    @Test fun playableAndTerminalDecisionsAreDistinct() {
        val playable = json.decodeFromString<SiloPlaybackStartResponse>(
            """{"protocol_version":3,"outcome":"playable","session_id":"session-1","playback_plan":{"protocol_version":3,"delivery":"original_http","stream":{"url":"/stream/session-1","protocol":"http_progressive"},"timeline":{"source_start_seconds":12.0,"player_start_seconds":12.0,"timeline_offset_seconds":0},"source":{"duration_seconds":90}}}"""
        )
        assertEquals("session-1", playable.audioPlan().first)
        assertEquals(12.0, playable.audioPlan().second.timeline.sourceStartSeconds, 0.0)

        val terminal = json.decodeFromString<SiloPlaybackStartResponse>(
            """{"protocol_version":3,"outcome":"adaptation_unavailable","terminal":{"reason":"audio_unsupported"}}"""
        )
        assertThrows(IllegalStateException::class.java) { terminal.audioPlan() }
    }
}
