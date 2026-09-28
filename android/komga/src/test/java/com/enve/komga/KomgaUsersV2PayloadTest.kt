package com.enve.komga

import com.enve.komga.dto.KomgaAgeRestrictionDto
import com.enve.komga.dto.KomgaSharedLibrariesUpdateDto
import com.enve.komga.dto.KomgaUserDto
import com.enve.komga.dto.KomgaUserUpdateDto
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class KomgaUsersV2PayloadTest {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        encodeDefaults = true
    }

    @Test
    fun decodesV2UserList() {
        val body = """
            [
              {"id":"0R9AMY3ADMMDZ","email":"admin@example.invalid","roles":["ADMIN","FILE_DOWNLOAD","KOBO_SYNC","KOREADER_SYNC","PAGE_STREAMING","USER"],"sharedAllLibraries":true,"sharedLibrariesIds":[],"labelsAllow":[],"labelsExclude":[]},
              {"id":"0RQVYQ88N7REZ","email":"reader@example.invalid","roles":["ADMIN","FILE_DOWNLOAD","USER"],"sharedAllLibraries":false,"sharedLibrariesIds":["0R9AMY55HMMS8"],"labelsAllow":["kids"],"labelsExclude":[],"ageRestriction":{"age":12,"restriction":"ALLOW_ONLY"}}
            ]
        """.trimIndent()

        val users = json.decodeFromString<List<KomgaUserDto>>(body)

        assertEquals(2, users.size)
        assertEquals(true, users[0].sharedAllLibraries)
        assertNull(users[0].ageRestriction)
        assertEquals(false, users[1].sharedAllLibraries)
        assertEquals(listOf("0R9AMY55HMMS8"), users[1].sharedLibrariesIds)
        assertEquals(listOf("kids"), users[1].labelsAllow)
        assertEquals(KomgaAgeRestrictionDto(12, "ALLOW_ONLY"), users[1].ageRestriction)
    }

    @Test
    fun decodesV2CreatedUser() {
        val body = """
            {"id":"0RQVYQ88N7REZ","email":"reader@example.invalid","roles":["FILE_DOWNLOAD","PAGE_STREAMING","USER"],"sharedAllLibraries":true,"sharedLibrariesIds":[],"labelsAllow":[],"labelsExclude":[]}
        """.trimIndent()

        val user = json.decodeFromString<KomgaUserDto>(body)

        assertEquals("0RQVYQ88N7REZ", user.id)
        assertEquals(listOf("FILE_DOWNLOAD", "PAGE_STREAMING", "USER"), user.roles)
    }

    @Test
    fun updateBodyOmitsUnsetFields() {
        assertEquals(
            """{"roles":["ADMIN","FILE_DOWNLOAD"]}""",
            json.encodeToString(KomgaUserUpdateDto(roles = listOf("ADMIN", "FILE_DOWNLOAD"))),
        )
        assertEquals(
            """{"sharedLibraries":{"all":false,"libraryIds":["0R9AMY55HMMS8"]}}""",
            json.encodeToString(
                KomgaUserUpdateDto(sharedLibraries = KomgaSharedLibrariesUpdateDto(false, listOf("0R9AMY55HMMS8"))),
            ),
        )
    }
}
