package com.enve.core.data.local

import kotlinx.serialization.Serializable

@Serializable
enum class FamilyProfileRole { ADULT, CHILD }

@Serializable
data class FamilyProfile(
    val id: String,
    val name: String,
    val role: FamilyProfileRole,
) {
    companion object {
        fun validId(id: String): Boolean = id.length in 1..128 && id.all {
            it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' || it == '_'
        }
    }
}

const val DEFAULT_ADULT_PROFILE_ID = "adult-default"
