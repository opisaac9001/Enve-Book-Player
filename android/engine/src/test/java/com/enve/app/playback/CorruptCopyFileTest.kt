package com.enve.app.playback

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

class CorruptCopyFileTest {
    private val file = File("/profile/playback/sleep-automation.json")

    @Test
    fun usesTimestampedName() {
        assertEquals(
            File("/profile/playback/sleep-automation.json.corrupt-42"),
            corruptCopyFile(file, 42L) { false },
        )
    }

    @Test
    fun neverReusesAnExistingRecoveryFile() {
        val taken = setOf(
            File("/profile/playback/sleep-automation.json.corrupt-42"),
            File("/profile/playback/sleep-automation.json.corrupt-42-1"),
        )
        assertEquals(
            File("/profile/playback/sleep-automation.json.corrupt-42-2"),
            corruptCopyFile(file, 42L) { it in taken },
        )
    }
}
