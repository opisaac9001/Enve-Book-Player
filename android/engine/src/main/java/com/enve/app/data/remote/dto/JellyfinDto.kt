package com.enve.app.data.remote.dto

import kotlinx.serialization.Serializable

@Serializable
data class JellyfinQuickConnectResult(
    val Authenticated: Boolean = false,
    val Secret: String = "",
    val Code: String = "",
    val DeviceId: String? = null,
    val DeviceName: String? = null,
    val AppName: String? = null,
    val AppVersion: String? = null,
    val DateAdded: String? = null,
)

@Serializable
data class JellyfinAuthenticateWithQuickConnectRequest(
    val Secret: String,
)

@Serializable
data class JellyfinAuthenticationResult(
    val AccessToken: String = "",
    val ServerId: String? = null,
    val User: JellyfinUserDto? = null,
)

@Serializable
data class JellyfinUserDto(
    val Id: String = "",
    val Name: String = "",
    val ServerId: String? = null,
)
