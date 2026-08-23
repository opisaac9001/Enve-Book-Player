package com.enve.app.data.links

import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.LinkedBookPair
import com.enve.core.data.local.LinkedBookPairDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookLinkAnalyzer
import com.enve.core.data.model.LinkedBookMatch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class BookLinkRepository @Inject constructor(
    private val bookCacheDao: BookCacheDao,
    private val linkedBookPairDao: LinkedBookPairDao,
) {
    private companion object {
        const val CANDIDATE_POOL_LIMIT = 20_000
    }

    suspend fun rebuildAutomaticLinks(limit: Int = 20000): Int = withContext(Dispatchers.IO) {
        val books = bookCacheDao.getBooksForLinking(limit).map { it.toBook() }
        var inserted = 0
        val now = System.currentTimeMillis()
        for (candidate in BookLinkAnalyzer.findPairs(books)) {
            val ebookKey = candidate.ebook.uniqueKey
            val audiobookKey = candidate.audiobook.uniqueKey
            val ebookExisting = linkedBookPairDao.getForEbook(ebookKey)
            val audiobookExisting = linkedBookPairDao.getForAudiobook(audiobookKey)
            if (ebookExisting == null && audiobookExisting == null) {
                linkedBookPairDao.upsert(
                    LinkedBookPair(
                        ebookKey = ebookKey,
                        audiobookKey = audiobookKey,
                        updatedAt = now,
                    ),
                )
                inserted++
            }
        }
        inserted
    }

    suspend fun linkCandidates(forBook: Book, query: String, limit: Int = 80): List<LinkedBookMatch> = withContext(Dispatchers.IO) {
        if (forBook.mediaType != AppMediaType.EBOOK && forBook.mediaType != AppMediaType.AUDIOBOOK) {
            return@withContext emptyList()
        }
        val needle = query.trim()
        val books = bookCacheDao.getBooksForLinking(CANDIDATE_POOL_LIMIT)
            .map { it.toBook() }
            .filter { candidate -> needle.isBlank() || candidate.matchesLinkQuery(needle) }
        BookLinkAnalyzer.rankMatches(forBook, books, limit)
    }

    suspend fun link(book: Book, counterpart: Book): Boolean = withContext(Dispatchers.IO) {
        val ebook = when {
            book.mediaType == AppMediaType.EBOOK && counterpart.mediaType == AppMediaType.AUDIOBOOK -> book
            book.mediaType == AppMediaType.AUDIOBOOK && counterpart.mediaType == AppMediaType.EBOOK -> counterpart
            else -> return@withContext false
        }
        val audiobook = if (ebook.uniqueKey == book.uniqueKey) counterpart else book
        val now = System.currentTimeMillis()
        linkedBookPairDao.deleteForEbook(ebook.uniqueKey)
        linkedBookPairDao.deleteForAudiobook(audiobook.uniqueKey)
        linkedBookPairDao.upsert(
            LinkedBookPair(
                ebookKey = ebook.uniqueKey,
                audiobookKey = audiobook.uniqueKey,
                updatedAt = now,
            ),
        )
        true
    }

    suspend fun unlink(forBook: Book): Boolean = withContext(Dispatchers.IO) {
        when (forBook.mediaType) {
            AppMediaType.EBOOK -> linkedBookPairDao.deleteForEbook(forBook.uniqueKey)
            AppMediaType.AUDIOBOOK -> linkedBookPairDao.deleteForAudiobook(forBook.uniqueKey)
            else -> return@withContext false
        }
        true
    }

    suspend fun linkedAudiobook(forBook: Book): Book? = withContext(Dispatchers.IO) {
        if (forBook.mediaType != AppMediaType.EBOOK) return@withContext null
        val pair = linkedBookPairDao.getForEbook(forBook.uniqueKey) ?: return@withContext null
        bookCacheDao.getByCacheKey(pair.audiobookKey)?.toBook()
    }

    suspend fun linkedEbook(forBook: Book): Book? = withContext(Dispatchers.IO) {
        if (forBook.mediaType != AppMediaType.AUDIOBOOK) return@withContext null
        val pair = linkedBookPairDao.getForAudiobook(forBook.uniqueKey) ?: return@withContext null
        bookCacheDao.getByCacheKey(pair.ebookKey)?.toBook()
    }

    fun observeLinkedPairs(): Flow<List<LinkedBookPair>> = linkedBookPairDao.observeAll()

    suspend fun resolvePair(pair: LinkedBookPair): Pair<Book, Book>? = withContext(Dispatchers.IO) {
        val ebook = bookCacheDao.getByCacheKey(pair.ebookKey)?.toBook() ?: return@withContext null
        val audiobook = bookCacheDao.getByCacheKey(pair.audiobookKey)?.toBook() ?: return@withContext null
        ebook to audiobook
    }
}

private fun Book.matchesLinkQuery(query: String): Boolean {
    val needle = query.lowercase()
    val haystack = listOf(
        title,
        subtitle.orEmpty(),
        author.orEmpty(),
        narrator.orEmpty(),
        seriesName.orEmpty(),
    ).joinToString(" ").lowercase()
    return haystack.contains(needle)
}
