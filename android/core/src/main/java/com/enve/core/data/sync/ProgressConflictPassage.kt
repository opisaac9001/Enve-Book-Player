package com.enve.core.data.sync

enum class PassageAccuracy(val label: String) {
    EXACT("Exact spot"),
    APPROXIMATE("Approximate spot"),
}

data class ProgressConflictPassage(
    val text: String,
    val sectionTitle: String?,
    val accuracy: PassageAccuracy,
)
