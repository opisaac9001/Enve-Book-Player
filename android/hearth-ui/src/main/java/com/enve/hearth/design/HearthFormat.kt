package com.enve.hearth.design

import android.text.format.DateUtils
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import java.time.LocalDateTime
import java.util.Locale

object HearthFormat {

    fun progress(book: Book): Float {
        val p = if (book.mediaType == AppMediaType.EBOOK) (book.epubProgress ?: book.readProgress) else book.readProgress
        return p.coerceIn(0f, 1f)
    }

    fun timeLeft(book: Book): String? = when (book.mediaType) {
        AppMediaType.EBOOK -> {
            val pct = (progress(book) * 100).toInt()
            if (pct in 1..99) "$pct% read" else null
        }
        else -> {
            val remainingSec = (book.duration - book.currentTime).coerceAtLeast(0L)
            if (book.duration <= 0L) null else durationLeft(remainingSec)
        }
    }

    fun heroOverline(book: Book): String = when {
        book.mediaType == AppMediaType.EBOOK -> {
            val pct = (progress(book) * 100).toInt()
            if (pct >= 1) "$pct% read" else "Unread"
        }
        book.podcastName != null -> "Podcast"
        book.chapters.size > 1 -> {
            val i = book.chapters.indexOfLast { it.startTime <= book.currentTime }.coerceAtLeast(0)
            "Chapter ${i + 1} of ${book.chapters.size}"
        }
        else -> "Audiobook"
    }

    fun chapterTicks(book: Book): List<Float> =
        if (book.duration <= 0L) emptyList()
        else book.chapters.drop(1).map { it.startTime.toFloat() / book.duration }.filter { it in 0.005f..0.995f }

    fun greeting(now: LocalDateTime = LocalDateTime.now()): String {
        val weekday = now.dayOfWeek.getDisplayName(java.time.format.TextStyle.FULL, Locale.getDefault())
        val part = when (now.hour) {
            in 5..11 -> "morning"
            in 12..16 -> "afternoon"
            in 17..21 -> "evening"
            in 22..23 -> "night"
            else -> "late night"
        }
        return "$weekday $part"
    }

    fun relativeAgo(epochMillis: Long): String? {
        if (epochMillis <= 0L) return null
        return DateUtils.getRelativeTimeSpanString(
            epochMillis, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS,
        ).toString().replaceFirstChar { it.lowercase(Locale.getDefault()) }
    }

    private fun durationLeft(seconds: Long): String {
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        return when {
            h > 0 -> "${h}h ${m}m left"
            m > 0 -> "${m}m left"
            else -> "Nearly done"
        }
    }
}
