package com.enve.app.data.hardcover

import java.util.Locale

data class HardcoverIdentifiers(
    val isbn10: String? = null,
    val isbn13: String? = null,
    val asin: String? = null,
) {
    val isEmpty: Boolean get() = isbn10 == null && isbn13 == null && asin == null
}

data class HardcoverIdentifiedEdition(
    val edition: HardcoverEdition,
    val bookId: Int,
    val bookTitle: String,
    val isbn10: String?,
    val isbn13: String?,
    val asin: String?,
)

internal sealed interface HardcoverIdentifierMatch {
    data class Matched(val bookId: Int, val bookTitle: String, val edition: HardcoverEdition?) : HardcoverIdentifierMatch
    data object Conflict : HardcoverIdentifierMatch
    data object NoHit : HardcoverIdentifierMatch
}

private val isbnLabel = Regex("^ISBN(?:1[03])?:?")
private val asinPattern = Regex("^B0[0-9A-Z]{8}$")

private fun compactIdentifier(raw: String?): String? =
    raw?.uppercase(Locale.ROOT)
        ?.filterNot { it.isWhitespace() || it == '-' }
        ?.replaceFirst(isbnLabel, "")
        ?.takeIf { it.isNotEmpty() }

private fun Char.isAsciiDigit(): Boolean = this in '0'..'9'

internal fun hardcoverIsbn13(raw: String?): String? {
    val value = compactIdentifier(raw)?.takeIf { it.length == 13 && it.all(Char::isAsciiDigit) } ?: return null
    if (!value.startsWith("978") && !value.startsWith("979")) return null
    val sum = value.withIndex().sumOf { (index, char) -> (char - '0') * if (index % 2 == 0) 1 else 3 }
    return value.takeIf { sum % 10 == 0 }
}

internal fun hardcoverIsbn10(raw: String?): String? {
    val value = compactIdentifier(raw)?.takeIf { candidate ->
        candidate.length == 10 && candidate.take(9).all(Char::isAsciiDigit) && (candidate[9].isAsciiDigit() || candidate[9] == 'X')
    } ?: return null
    val sum = value.withIndex().sumOf { (index, char) -> (10 - index) * if (char == 'X') 10 else char - '0' }
    return value.takeIf { sum % 11 == 0 }
}

internal fun hardcoverAsin(raw: String?): String? = compactIdentifier(raw)?.takeIf(asinPattern::matches)

internal fun hardcoverIdentifiers(raw: String?): HardcoverIdentifiers =
    hardcoverIsbn13(raw)?.let { HardcoverIdentifiers(isbn13 = it) }
        ?: hardcoverIsbn10(raw)?.let { HardcoverIdentifiers(isbn10 = it) }
        ?: hardcoverAsin(raw)?.let { HardcoverIdentifiers(asin = it) }
        ?: HardcoverIdentifiers()

private fun HardcoverIdentifiedEdition.identifierPairs(identifiers: HardcoverIdentifiers) = listOf(
    identifiers.isbn13 to compactIdentifier(isbn13),
    identifiers.isbn10 to compactIdentifier(isbn10),
    identifiers.asin to compactIdentifier(asin),
).filter { (wanted, _) -> wanted != null }

internal fun hardcoverIdentifierMatch(
    identifiers: HardcoverIdentifiers,
    editions: List<HardcoverIdentifiedEdition>,
): HardcoverIdentifierMatch {
    if (identifiers.isEmpty) return HardcoverIdentifierMatch.NoHit
    val hits = editions
        .filter { edition -> edition.identifierPairs(identifiers).any { (wanted, actual) -> wanted == actual } }
        .distinctBy { it.edition.id }
    if (hits.isEmpty()) return HardcoverIdentifierMatch.NoHit
    val contradicted = hits.any { edition ->
        edition.identifierPairs(identifiers).any { (wanted, actual) -> actual != null && wanted != actual }
    }
    if (contradicted || hits.distinctBy { it.bookId }.size > 1) return HardcoverIdentifierMatch.Conflict
    val exact = hits.filter { candidate -> candidate.identifierPairs(identifiers).all { (wanted, actual) -> wanted == actual } }
    val selected = exact.singleOrNull() ?: return HardcoverIdentifierMatch.Conflict
    return HardcoverIdentifierMatch.Matched(selected.bookId, selected.bookTitle, selected.edition)
}
