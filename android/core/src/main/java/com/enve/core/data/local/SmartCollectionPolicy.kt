package com.enve.core.data.local

import com.enve.core.data.model.Book
import com.enve.core.data.model.ReadStatus

object SmartCollectionPolicy {
    val systemCollections = listOf(
        system("currently-listening", "Currently listening", "Books you're in the middle of", "AUDIOBOOK", "IN_PROGRESS"),
        system("finished", "Finished", "Books you've completed", status = "FINISHED"),
        system("abandoned", "Abandoned", "Books you've set aside", status = "ABANDONED"),
        system("on-hold", "On hold", "Books you've paused", status = "ON_HOLD"),
        system("unfinished", "Unfinished", "Books you haven't completed", status = "UNFINISHED"),
        system("recently-added", "Recently added", "Books added in the last 30 days", addedWithinDays = 30),
        system("long-books", "Long books", "Audiobooks over 20 hours", "AUDIOBOOK", length = "LONG"),
        system("short-books", "Short books", "Audiobooks under 5 hours", "AUDIOBOOK", length = "SHORT"),
    )

    fun matches(collection: CustomSmartCollection, book: Book, nowMs: Long = System.currentTimeMillis()): Boolean {
        collection.rulesJson?.let {
            return matches(collection.ruleGroup(), book, nowMs)
        }
        collection.mediaType?.let { if (book.mediaType.name != it) return false }
        val finished = book.isFinished || book.readStatus == ReadStatus.COMPLETED
        when (collection.status) {
            "IN_PROGRESS" -> if (finished || book.readStatus == ReadStatus.ON_HOLD || book.progress <= 0f) return false
            "FINISHED" -> if (!finished) return false
            "UNFINISHED" -> if (finished) return false
            "UNREAD" -> if (book.progress > 0f || book.readStatus != ReadStatus.UNREAD) return false
            "ON_HOLD" -> if (book.readStatus != ReadStatus.ON_HOLD) return false
            "ABANDONED" -> if (book.serverReadStatus != "ABANDONED") return false
        }
        when (collection.length) {
            "LONG" -> if (book.duration <= 20 * 3600L) return false
            "SHORT" -> if (book.duration <= 0L || book.duration >= 5 * 3600L) return false
        }
        collection.addedWithinDays?.let { days ->
            if (book.addedOn <= 0L || book.addedOn < nowMs - days * 86_400_000L) return false
        }
        collection.query?.trim()?.takeIf(String::isNotEmpty)?.let { query ->
            if (listOfNotNull(book.title, book.author, book.narrator, book.seriesName)
                    .none { it.contains(query, ignoreCase = true) }) return false
        }
        return true
    }

    fun matches(group: SmartCollectionRuleGroup, book: Book, nowMs: Long = System.currentTimeMillis()): Boolean {
        if (group.rules.isEmpty()) return false
        return if (group.logicOperator == "OR") group.rules.any { matchesRule(it, book, nowMs) }
        else group.rules.all { matchesRule(it, book, nowMs) }
    }

    private fun matchesRule(rule: SmartCollectionRule, book: Book, nowMs: Long): Boolean {
        val finished = book.isFinished || book.readStatus == ReadStatus.COMPLETED
        return when (rule.field) {
            "author" -> matchesText(book.author.orEmpty(), rule)
            "narrator" -> matchesText(book.narrator.orEmpty(), rule)
            "genre" -> matchesTexts(book.categories, rule)
            "mediaType" -> matchesText(book.mediaType.name, rule)
            "readStatus" -> matchesText(book.readStatus.name, rule)
            "search" -> matchesTexts(listOfNotNull(book.title, book.author, book.narrator, book.seriesName), rule)
            "duration" -> matchesNumber(book.duration / 3600.0, rule)
            "progress" -> matchesNumber(book.progress.toDouble(), rule)
            "releaseYear" -> book.publishedDate?.take(4)?.toDoubleOrNull()?.let { matchesNumber(it, rule) } ?: false
            "isFinished" -> matchesBoolean(finished, rule)
            "isAbandoned" -> matchesBoolean(book.serverReadStatus == "ABANDONED", rule)
            "isDownloaded" -> matchesBoolean(book.isDownloaded, rule)
            "dateAdded" -> matchesDate(book.addedOn, rule, nowMs)
            "lastPlayed" -> matchesDate(book.lastReadTime, rule, nowMs)
            else -> false
        }
    }

    private fun matchesText(value: String, rule: SmartCollectionRule): Boolean = when (rule.operator) {
        "equals" -> value.equals(rule.value, ignoreCase = true)
        "notEquals" -> !value.equals(rule.value, ignoreCase = true)
        "contains" -> value.contains(rule.value, ignoreCase = true)
        else -> false
    }

    private fun matchesTexts(values: List<String>, rule: SmartCollectionRule): Boolean =
        if (rule.operator == "notEquals") values.none { it.equals(rule.value, ignoreCase = true) }
        else values.any { matchesText(it, rule) }

    private fun matchesNumber(value: Double, rule: SmartCollectionRule): Boolean {
        val target = rule.value.toDoubleOrNull() ?: return false
        return when (rule.operator) {
            "equals" -> kotlin.math.abs(value - target) < 0.001
            "notEquals" -> kotlin.math.abs(value - target) >= 0.001
            "greaterThan" -> value > target
            "lessThan" -> value < target
            else -> false
        }
    }

    private fun matchesBoolean(value: Boolean, rule: SmartCollectionRule): Boolean = when (rule.operator) {
        "isTrue" -> value
        "isFalse" -> !value
        "equals" -> value == rule.value.toBooleanStrictOrNull()
        else -> false
    }

    private fun matchesDate(timestamp: Long, rule: SmartCollectionRule, nowMs: Long): Boolean {
        val days = rule.value.toLongOrNull() ?: return false
        if (timestamp <= 0 || days < 0) return false
        val cutoff = nowMs - days * 86_400_000L
        return when (rule.operator) {
            "greaterThan" -> timestamp > cutoff
            "lessThan" -> timestamp < cutoff
            else -> false
        }
    }

    private fun system(
        key: String,
        name: String,
        description: String,
        mediaType: String? = null,
        status: String = "ANY",
        length: String = "ANY",
        addedWithinDays: Int? = null,
    ) = CustomSmartCollection(
        id = "system-$key",
        name = name,
        description = description,
        mediaType = mediaType,
        status = status,
        length = length,
        addedWithinDays = addedWithinDays,
        query = null,
        createdAt = 0L,
        updatedAt = 0L,
    )
}
