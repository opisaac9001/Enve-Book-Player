package com.enve.engine.playback

data class ReadAloudLyricLine(
    val id: String,
    val text: String,
    val clipIndex: Int,
    val startMs: Long,
    val endMs: Long,
)
