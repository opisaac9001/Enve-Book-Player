package com.enve.engine.playback

data class PlayerReadAloudState(
    val bookKey: String? = null,
    val available: Boolean = false,
    val loading: Boolean = false,
    val lines: List<ReadAloudLyricLine> = emptyList(),
    val activeLineId: String? = null,
    val error: String? = null,
)
