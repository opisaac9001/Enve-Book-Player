package com.enve.app.data.metadata

import com.enve.core.data.model.AppMediaType
import kotlinx.serialization.Serializable

@Serializable
data class MetadataMatchCandidate(
    val id: String,
    val externalId: String,
    val source: MetadataCandidateSource,
    val mediaType: AppMediaType,
    val title: String,
    val subtitle: String? = null,
    val author: String? = null,
    val authors: List<String> = emptyList(),
    val narrator: String? = null,
    val narrators: List<String> = emptyList(),
    val publisher: String? = null,
    val publishedDate: String? = null,
    val publishedYear: Int? = null,
    val isbn: String? = null,
    val coverUrl: String? = null,
    val durationSec: Long? = null,
    val pageCount: Int? = null,
    val seriesName: String? = null,
    val seriesPosition: String? = null,
    val description: String? = null,
    val categories: List<String> = emptyList(),
    val language: String? = null,
    val confidence: Double,
    val matchReason: String,
)

@Serializable
enum class MetadataCandidateSource {
    AUDIOBOOK_CATALOG,
    GOOGLE_BOOKS,
    OPEN_LIBRARY,
}

data class MetadataMatchFileSnapshot(
    val title: String,
    val author: String?,
    val durationSec: Long,
    val isbn: String?,
    val seriesNumber: Int?,
    val fileName: String? = null,
    val folderName: String? = null,
)

data class MetadataMatchScore(
    val total: Double,
    val durationScore: Double,
    val titleScore: Double,
    val authorScore: Double,
    val hasDuration: Boolean,
    val requiresManualReview: Boolean,
) {
    val formattedTotal: String = "${(total * 100).toInt()}%"
}
