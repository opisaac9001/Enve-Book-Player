package com.enve.app.data.remote.dto

import kotlinx.serialization.Serializable

@Serializable
data class GrimmoryCreateShelfRequest(
    val name: String,
    val icon: String,
    val publicShelf: Boolean = false,
)

@Serializable
data class GrimmoryShelfAssignmentRequest(
    val bookIds: List<Long>,
    val shelvesToAssign: List<Long>,
    val shelvesToUnassign: List<Long>,
)
