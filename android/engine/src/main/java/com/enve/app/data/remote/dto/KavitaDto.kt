package com.enve.app.data.remote.dto

import kotlinx.serialization.Serializable

@Serializable
data class KavitaAccountDto(
    val id: Int = 0,
    val username: String? = null,
)

@Serializable
data class KavitaProfileStatBarDto(
    val booksRead: Int = 0,
    val comicsRead: Int = 0,
    val pagesRead: Int = 0,
    val wordsRead: Int = 0,
    val authorsRead: Int = 0,
    val reviews: Int = 0,
    val ratings: Int = 0,
)

@Serializable
data class KavitaUserReadStatisticsDto(
    val totalPagesRead: Long = 0L,
    val totalWordsRead: Long = 0L,
    val timeSpentReading: Long = 0L,
    val lastActiveUtc: String? = null,
    val avgHoursPerWeekSpentReading: Double = 0.0,
)

@Serializable
data class KavitaSeriesDto(
    val id: Int = 0,
    val name: String? = null,
)

@Serializable
data class KavitaAnnotationDto(
    val id: Int = 0,
    val selectedText: String? = null,
    val commentPlainText: String? = null,
    val chapterTitle: String? = null,
    val seriesName: String? = null,
    val pageNumber: Int = 0,
    val createdUtc: String? = null,
)
