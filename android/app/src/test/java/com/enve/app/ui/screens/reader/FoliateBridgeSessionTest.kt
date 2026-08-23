package com.enve.app.ui.screens.reader

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FoliateBridgeSessionTest {
    @Test
    fun initialStateCanOnlyBeServedOnce() {
        val session = FoliateBridgeSession(capability = "secret")

        assertTrue(session.serveInitialState())
        assertFalse(session.serveInitialState())
    }

    @Test
    fun capabilityAndStrictlyIncreasingSequenceAreRequired() {
        val session = FoliateBridgeSession(capability = "secret")
        assertTrue(session.serveInitialState())

        assertFalse(session.accepts(capability = "wrong", sequence = 1))
        assertFalse(session.accepts(capability = "secret", sequence = 2))
        assertTrue(session.accepts(capability = "secret", sequence = 1))
        assertFalse(session.accepts(capability = "secret", sequence = 1))
        assertTrue(session.accepts(capability = "secret", sequence = 2))
    }

    @Test
    fun messagesAreRejectedBeforeHandshake() {
        val session = FoliateBridgeSession(capability = "secret")

        assertFalse(session.accepts(capability = "secret", sequence = 1))
    }

    @Test
    fun runtimeSupportsIndentAndLocksPagingDuringTextSelection() {
        val source = listOf(
            File("src/main/assets/foliate-reader.js"),
            File("app/src/main/assets/foliate-reader.js"),
        ).first(File::isFile).readText()

        assertTrue(source.contains("preferences.paragraphIndent"))
        assertTrue(source.contains("selectionGestureLocked"))
        assertTrue(source.contains("event.stopImmediatePropagation()"))
        assertTrue(source.contains("{ capture: true, passive: true }"))
        assertTrue(source.contains("setTimeout(publishSelection, 75)"))
        assertTrue(source.contains("doc.addEventListener('selectionchange', scheduleSelectionPublish)"))
        assertTrue(source.contains("doc.addEventListener('touchcancel'"))
        assertTrue(source.contains("if (mediaType.includes('html'))"))
        assertTrue(source.contains("doc = new DOMParser().parseFromString(value, 'text/html')"))
        assertTrue(source.contains("compatibility:Invalid ${'$'}{mediaType || 'XML'} publication resource"))
    }
}
