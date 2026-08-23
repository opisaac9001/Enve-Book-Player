package com.enve.app.data.grimmory

import com.enve.app.data.grimmory.auth.requiredGrimmoryOidcState
import com.enve.app.data.remote.dto.OidcStateDto
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class GrimmoryOidcStateTest {

    @Test
    fun serverStateIsRequired() {
        assertEquals(
            "server-state",
            OidcStateDto(state = "server-state").requiredGrimmoryOidcState(),
        )
        assertThrows(IllegalStateException::class.java) {
            OidcStateDto(state = "").requiredGrimmoryOidcState()
        }
        assertThrows(IllegalStateException::class.java) {
            OidcStateDto(state = null).requiredGrimmoryOidcState()
        }
    }
}
