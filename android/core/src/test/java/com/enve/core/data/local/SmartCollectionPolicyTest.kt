package com.enve.core.data.local

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReadStatus
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class SmartCollectionPolicyTest {
    @Test
    fun currentlyListeningExcludesFinishedAndOnHoldBooks() {
        val collection = SmartCollectionPolicy.systemCollections.first { it.id == "system-currently-listening" }
        val playing = Book(id = "a", title = "Novel", duration = 100, currentTime = 20)
        assertTrue(SmartCollectionPolicy.matches(collection, playing))
        assertFalse(SmartCollectionPolicy.matches(collection, playing.copy(readStatus = ReadStatus.ON_HOLD)))
        assertFalse(SmartCollectionPolicy.matches(collection, playing.copy(isFinished = true)))
        assertFalse(SmartCollectionPolicy.matches(collection, playing.copy(mediaType = AppMediaType.EBOOK)))
    }

    @Test
    fun customRuleCombinesAllFilters() {
        val rule = CustomSmartCollection(
            id = "test", name = "Recent short ebooks", description = null, mediaType = "EBOOK",
            status = "UNFINISHED", length = "ANY", addedWithinDays = 7, query = "wonderland",
            createdAt = 0, updatedAt = 0,
        )
        val now = 1_000_000_000L
        val book = Book(id = "b", title = "Alice in Wonderland", mediaType = AppMediaType.EBOOK,
            addedOn = now - 3 * 86_400_000L)
        assertTrue(SmartCollectionPolicy.matches(rule, book, now))
        assertFalse(SmartCollectionPolicy.matches(rule, book.copy(addedOn = now - 8 * 86_400_000L), now))
        assertFalse(SmartCollectionPolicy.matches(rule, book.copy(readStatus = ReadStatus.COMPLETED), now))
        assertFalse(SmartCollectionPolicy.matches(rule, book.copy(title = "Another book"), now))
    }

    @Test
    fun ruleGroupsEvaluateAllOrAnyAndKeepLegacyShelves() {
        val now = 1_000_000_000L
        val recent = SmartCollectionRule("dateAdded", "greaterThan", "7")
        val author = SmartCollectionRule("author", "contains", "Le Guin")
        val base = CustomSmartCollection("rules", "Rules", null, null, "ANY", "ANY", null, null, 0, 0)
        val book = Book(id = "c", title = "Earthsea", author = "Ursula K. Le Guin",
            addedOn = now - 3 * 86_400_000L)
        val andShelf = base.copy(rulesJson = Json.encodeToString(SmartCollectionRuleGroup("AND", listOf(recent, author))))
        val orShelf = base.copy(rulesJson = Json.encodeToString(SmartCollectionRuleGroup("OR", listOf(recent, author))))
        assertTrue(SmartCollectionPolicy.matches(andShelf, book, now))
        assertFalse(SmartCollectionPolicy.matches(andShelf, book.copy(addedOn = now - 10 * 86_400_000L), now))
        assertTrue(SmartCollectionPolicy.matches(orShelf, book.copy(addedOn = now - 10 * 86_400_000L), now))
        assertFalse(SmartCollectionPolicy.matches(orShelf, book.copy(author = "Someone else", addedOn = 0), now))
    }

    @Test
    fun booleanAndNumericRulesUseBookValues() {
        val base = CustomSmartCollection("rules", "Rules", null, null, "ANY", "ANY", null, null, 0, 0)
        val rules = SmartCollectionRuleGroup(rules = listOf(
            SmartCollectionRule("isDownloaded", "isTrue", ""),
            SmartCollectionRule("duration", "greaterThan", "10"),
            SmartCollectionRule("progress", "lessThan", "0.5"),
        ))
        val shelf = base.copy(rulesJson = Json.encodeToString(rules))
        val book = Book(id = "d", title = "Long book", duration = 12 * 3600, currentTime = 3600, isDownloaded = true)
        assertTrue(SmartCollectionPolicy.matches(shelf, book))
        assertFalse(SmartCollectionPolicy.matches(shelf, book.copy(isDownloaded = false)))
        assertFalse(SmartCollectionPolicy.matches(shelf, book.copy(duration = 8 * 3600)))
    }

    @Test
    fun abandonedSystemShelfUsesServerStatus() {
        val shelf = SmartCollectionPolicy.systemCollections.first { it.id == "system-abandoned" }
        val book = Book(id = "e", title = "Paused", serverReadStatus = "ABANDONED")
        assertTrue(SmartCollectionPolicy.matches(shelf, book))
        assertFalse(SmartCollectionPolicy.matches(shelf, book.copy(serverReadStatus = null)))
    }

    @Test
    fun notEqualsChecksEveryGenreAndSearchField() {
        val book = Book(id = "f", title = "Earthsea", author = "Ursula Le Guin", categories = listOf("Fantasy", "Adventure"))
        assertFalse(SmartCollectionPolicy.matches(
            SmartCollectionRuleGroup(rules = listOf(SmartCollectionRule("genre", "notEquals", "Fantasy"))), book,
        ))
        assertTrue(SmartCollectionPolicy.matches(
            SmartCollectionRuleGroup(rules = listOf(SmartCollectionRule("genre", "notEquals", "Mystery"))), book,
        ))
        assertFalse(SmartCollectionPolicy.matches(
            SmartCollectionRuleGroup(rules = listOf(SmartCollectionRule("search", "notEquals", "Earthsea"))), book,
        ))
    }
}
