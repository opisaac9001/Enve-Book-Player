package com.enve.core.data.remote.dto

import kotlinx.serialization.Serializable

@Serializable
data class LoginRequest(
    val username: String,
    val password: String,
)

@Serializable
data class AuthResponse(
    val accessToken: String,
    val refreshToken: String? = null,
)

@Serializable
data class RefreshRequest(
    val refreshToken: String,
)

@Serializable
data class AbsLoginRequest(
    val username: String,
    val password: String,
)

@Serializable
data class AbsLoginResponse(
    val user: AbsUserDto? = null,
    val userDefaultLibraryId: String? = null,
    val accessToken: String? = null,
    val refreshToken: String? = null,
)

@Serializable
data class AbsUserDto(
    val id: String? = null,
    val username: String? = null,
    val token: String? = null,
    val accessToken: String? = null,
    val refreshToken: String? = null,
)
