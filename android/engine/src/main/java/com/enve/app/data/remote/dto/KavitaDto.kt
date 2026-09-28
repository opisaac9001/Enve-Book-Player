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
data class KavitaLibraryDto(
    val id: Int,
    val name: String,
    val type: Int = 0,
)

@Serializable
data class KavitaSeriesDto(
    val id: Int = 0,
    val name: String? = null,
    val libraryId: Int? = null,
    val format: Int = KavitaMangaFormat.UNKNOWN,
    val pages: Int = 0,
    val pagesRead: Int = 0,
    val created: String? = null,
    val latestReadDate: String? = null,
)

object KavitaMangaFormat {
    const val IMAGE = 0
    const val ARCHIVE = 1
    const val UNKNOWN = 2
    const val EPUB = 3
    const val PDF = 4
}

@Serializable
data class KavitaSeriesFilterDto(
    val statements: List<KavitaFilterStatementDto>,
    val combination: Int = COMBINATION_AND,
    val sortOptions: KavitaSortOptionsDto = KavitaSortOptionsDto(),
) {
    companion object {
        private const val FIELD_LIBRARY = 19
        private const val COMPARISON_EQUAL = 0
        private const val COMBINATION_AND = 1

        fun forLibrary(libraryId: String?): KavitaSeriesFilterDto = KavitaSeriesFilterDto(
            statements = listOfNotNull(
                libraryId?.let { KavitaFilterStatementDto(FIELD_LIBRARY, COMPARISON_EQUAL, it) },
            ),
        )
    }
}

@Serializable
data class KavitaFilterStatementDto(
    val field: Int,
    val comparison: Int,
    val value: String,
)

@Serializable
data class KavitaSortOptionsDto(
    val sortField: Int = SORT_CREATED,
    val isAscending: Boolean = false,
) {
    private companion object {
        const val SORT_CREATED = 2
    }
}

@Serializable
data class KavitaVolumeDto(
    val id: Int,
    val chapters: List<KavitaChapterDto> = emptyList(),
)

@Serializable
data class KavitaChapterDto(
    val id: Int,
    val pages: Int = 0,
)

@Serializable
data class KavitaProgressDto(
    val pageNum: Int = 0,
    val lastModifiedUtc: String? = null,
)

@Serializable
data class KavitaSaveProgressDto(
    val seriesId: Int,
    val libraryId: Int,
    val volumeId: Int,
    val chapterId: Int,
    val pageNum: Int,
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
