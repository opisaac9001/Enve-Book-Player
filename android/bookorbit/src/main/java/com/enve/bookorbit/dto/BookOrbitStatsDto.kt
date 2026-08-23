package com.enve.bookorbit.dto

import kotlinx.serialization.Serializable

@Serializable
data class BookOrbitStatisticsSummaryDto(
    val trackedBooks: Int = 0,
    val startedBooks: Int = 0,
    val inProgressBooks: Int = 0,
    val completedBooks: Int = 0,
    val meanProgressPercent: Double = 0.0,
)

@Serializable
data class BookOrbitDailyReadingDto(
    val day: String,
    val readingSeconds: Long = 0L,
    val progressDelta: Double = 0.0,
    val eventsCount: Int = 0,
    val bySource: Map<String, Long> = emptyMap(),
)

@Serializable
data class BookOrbitSourceSliceDto(
    val bucket: String,
    val readingSeconds: Long = 0L,
)

@Serializable
data class BookOrbitSourceDistributionDto(
    val totalSeconds: Long = 0L,
    val slices: List<BookOrbitSourceSliceDto> = emptyList(),
)

@Serializable
data class BookOrbitPeakHourDto(
    val hour: Int,
    val readingSeconds: Long = 0L,
    val eventsCount: Int = 0,
    val byFormat: Map<String, Long> = emptyMap(),
    val bySource: Map<String, Long> = emptyMap(),
)

@Serializable
data class BookOrbitFavoriteDayDto(
    val dayOfWeek: Int,
    val readingSeconds: Long = 0L,
    val eventsCount: Int = 0,
    val byFormat: Map<String, Long> = emptyMap(),
    val bySource: Map<String, Long> = emptyMap(),
)

@Serializable
data class BookOrbitCompletionTimelinePointDto(
    val year: Int,
    val month: Int,
    val count: Int = 0,
)

@Serializable
data class BookOrbitProgressFunnelDto(
    val started: Int = 0,
    val reached25: Int = 0,
    val reached50: Int = 0,
    val reached75: Int = 0,
    val completed: Int = 0,
)

@Serializable
data class BookOrbitProgressFunnelComparisonDto(
    val days: Int = 0,
    val current: BookOrbitProgressFunnelDto = BookOrbitProgressFunnelDto(),
    val previous: BookOrbitProgressFunnelDto? = null,
)

@Serializable
data class BookOrbitCompletionLatencyBucketDto(
    val label: String,
    val minDays: Int = 0,
    val maxDays: Int? = null,
    val count: Int = 0,
)

@Serializable
data class BookOrbitCompletionLatencyDto(
    val totalCompletions: Int = 0,
    val medianDays: Double? = null,
    val percentile75Days: Double? = null,
    val percentile90Days: Double? = null,
    val buckets: List<BookOrbitCompletionLatencyBucketDto> = emptyList(),
)

@Serializable
data class BookOrbitGenreReadingTimeDto(
    val genre: String,
    val readingSeconds: Long = 0L,
    val bySource: Map<String, Long> = emptyMap(),
)

@Serializable
data class BookOrbitReadingGoalWidgetDto(
    val goalBooks: Int? = null,
    val completedBooks: Int = 0,
    val year: Int = 0,
)

@Serializable
data class BookOrbitReadingStreakWidgetDto(
    val currentStreak: Int = 0,
    val longestStreak: Int = 0,
    val lastSevenDays: List<Boolean> = emptyList(),
)

@Serializable
data class BookOrbitLibraryOverviewWidgetDto(
    val totalBooks: Int = 0,
    val totalAuthors: Int = 0,
    val totalSeries: Int = 0,
    val totalStorageBytes: Long = 0L,
    val booksAddedThisYear: Int = 0,
)

@Serializable
data class BookOrbitYearProjectionWidgetDto(
    val projectedBooks: Int = 0,
    val projectedPages: Int = 0,
    val projectedHours: Int = 0,
    val booksCompletedYtd: Int = 0,
    val daysRemaining: Int = 0,
    val trend: String? = null,
)

@Serializable
data class BookOrbitReadingRhythmDayDto(
    val date: String,
    val readingSeconds: Long = 0L,
)

@Serializable
data class BookOrbitReadingRhythmWidgetDto(
    val days: List<BookOrbitReadingRhythmDayDto> = emptyList(),
    val consistencyPercent: Double = 0.0,
    val avgSecondsPerDay: Double = 0.0,
    val activeDays: Int = 0,
    val totalDays: Int = 0,
)

@Serializable
data class BookOrbitMonthlyChallengeWidgetDto(
    val challengeType: String? = null,
    val title: String = "",
    val description: String = "",
    val progress: Double = 0.0,
    val target: Double = 0.0,
    val completed: Boolean = false,
    val month: Int = 0,
    val year: Int = 0,
)

@Serializable
data class BookOrbitDiversityScoreWidgetDto(
    val score: Double = 0.0,
    val label: String = "",
    val genreScore: Double = 0.0,
    val authorScore: Double = 0.0,
    val eraScore: Double = 0.0,
    val languageScore: Double = 0.0,
    val booksAnalyzed: Int = 0,
)

@Serializable
data class BookOrbitReadingDnaWidgetDto(
    val archetype: String = "",
    val lengthScore: Double = 0.0,
    val varietyScore: Double = 0.0,
    val rhythmScore: Double = 0.0,
    val timeScore: Double = 0.0,
    val speedScore: Double = 0.0,
    val lengthLabel: String = "",
    val varietyLabel: String = "",
    val rhythmLabel: String = "",
    val timeLabel: String = "",
    val speedLabel: String = "",
    val booksAnalyzed: Int = 0,
)

@Serializable
data class BookOrbitHighlightOfTheDayWidgetDto(
    val text: String = "",
    val note: String? = null,
    val bookTitle: String? = null,
    val bookId: Int = 0,
    val hasCover: Boolean = false,
    val chapterTitle: String? = null,
    val createdAt: String? = null,
)

@Serializable
data class BookOrbitAchievementItemDto(
    val key: String,
    val groupKey: String? = null,
    val tier: Int? = null,
    val category: String,
    val name: String,
    val description: String = "",
    val iconName: String? = null,
    val rarity: String = "common",
    val threshold: Double? = null,
    val hidden: Boolean = false,
    val sortOrder: Int = 0,
    val earned: Boolean = false,
    val awardedAt: String? = null,
    val currentProgress: Double? = null,
)

@Serializable
data class BookOrbitAchievementCategoryDto(
    val key: String,
    val label: String,
    val earnedCount: Int = 0,
    val totalCount: Int = 0,
    val achievements: List<BookOrbitAchievementItemDto> = emptyList(),
)

@Serializable
data class BookOrbitAchievementCatalogueDto(
    val categories: List<BookOrbitAchievementCategoryDto> = emptyList(),
    val totalEarned: Int = 0,
    val totalAvailable: Int = 0,
)
