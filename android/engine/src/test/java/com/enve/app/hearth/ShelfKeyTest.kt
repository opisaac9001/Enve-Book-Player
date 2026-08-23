package com.enve.app.hearth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ShelfKeyTest {
    @Test
    fun `parses shelf key when connection id contains separators`() {
        val reference = parseShelfKey("grimmory|http://server:6060|reader|regular|7")

        assertEquals(
            ShelfRef(
                connectionId = "grimmory|http://server:6060|reader",
                shelfId = 7,
                kind = ShelfKind.GRIMMORY_REGULAR,
            ),
            reference,
        )
    }

    @Test
    fun `parses magic and BookOrbit shelf suffixes`() {
        assertEquals(
            ShelfKind.GRIMMORY_MAGIC,
            parseShelfKey("grimmory|http://server|reader|magic|3")?.kind,
        )
        assertEquals(
            ShelfKind.BOOKORBIT,
            parseShelfKey("bookorbit|https://server|reader|bookorbit|12")?.kind,
        )
    }

    @Test
    fun `rejects malformed shelf keys`() {
        assertNull(parseShelfKey("grimmory|regular"))
        assertNull(parseShelfKey("grimmory|http://server|reader|unknown|7"))
    }
}
