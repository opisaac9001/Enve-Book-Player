package com.enve.engine.library

import com.enve.core.data.model.Book
import com.enve.core.data.model.BrowseGroup
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.Library
import com.enve.core.data.model.HistorySession
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

data class LibraryMetadataEdit(
    val title: String,
    val subtitle: String? = null,
    val author: String? = null,
    val narrator: String? = null,
    val description: String? = null,
    val seriesName: String? = null,
    val seriesNumber: String? = null,
    val publisher: String? = null,
    val publishedDate: String? = null,
    val isbn13: String? = null,
    val language: String? = null,
    val pageCount: Int? = null,
    val categories: List<String> = emptyList(),
)

data class LibraryMetadataMatch(
    val id: String,
    val externalId: String,
    val sourceName: String,
    val title: String,
    val subtitle: String? = null,
    val author: String? = null,
    val narrator: String? = null,
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

data class LibraryLinkCandidate(
    val book: Book,
    val confidence: Int,
)

enum class LibraryDownloadStatus {
    IDLE,
    QUEUED,
    DOWNLOADING,
    COMPLETED,
    FAILED,
    CANCELLED,
}

data class LibraryDownloadState(
    val status: LibraryDownloadStatus = LibraryDownloadStatus.IDLE,
    val progress: Float = 0f,
    val completedItems: Int = 0,
    val totalItems: Int = 0,
    val errorMessage: String? = null,
) {
    val isActive: Boolean
        get() = status == LibraryDownloadStatus.QUEUED || status == LibraryDownloadStatus.DOWNLOADING
}

data class LibraryEditionLink(val ebookKey: String, val audiobookKey: String)

data class BookOrbitCollectionEdit(
    val name: String,
    val description: String? = null,
    val icon: String = "FolderOpen",
    val syncToKobo: Boolean = false,
)

data class LibraryShelfPage(
    val items: List<Book>,
    val total: Int,
    val page: Int,
    val hasMore: Boolean,
)

data class BookOrbitCollectionMembership(
    val collection: BrowseGroup,
    val containsBook: Boolean,
)

data class LibraryConnectionOption(val id: String, val name: String)

interface LibraryFacade {

    val historySessions: Flow<List<HistorySession>>

    val continueBooks: Flow<List<Book>>

    val editionLinks: Flow<List<LibraryEditionLink>>

    val recentlyAdded: Flow<List<Book>>

    val downloaded: Flow<List<Book>>

    val allBooks: Flow<List<Book>>

    val totalCount: Flow<Int>

    val libraries: Flow<List<Library>>

    suspend fun browseSeries(): List<BrowseGroup>

    suspend fun browseAuthors(): List<BrowseGroup>

    suspend fun browseShelves(): List<BrowseGroup>

    suspend fun booksInSeries(name: String): List<Book>

    suspend fun booksByAuthor(name: String): List<Book>

    suspend fun booksInShelf(key: String): List<Book>

    suspend fun shelfBooksPage(key: String, page: Int, size: Int = 60, query: String? = null): LibraryShelfPage

    suspend fun createBookOrbitCollection(connectionId: String, edit: BookOrbitCollectionEdit): BrowseGroup?
    suspend fun updateBookOrbitCollection(collection: BrowseGroup, edit: BookOrbitCollectionEdit): BrowseGroup?
    suspend fun deleteBookOrbitCollection(collection: BrowseGroup): Boolean
    suspend fun addBookToBookOrbitCollection(collection: BrowseGroup, book: Book): Boolean
    suspend fun addBooksToBookOrbitCollection(collection: BrowseGroup, books: List<Book>): Boolean
    suspend fun removeBookFromBookOrbitCollection(collection: BrowseGroup, book: Book): Boolean
    suspend fun reorderBookOrbitCollections(connectionId: String, orderedKeys: List<String>): Boolean
    suspend fun bookOrbitCollectionsForBook(book: Book): List<BookOrbitCollectionMembership>
    suspend fun bookOrbitAdminConnections(): List<LibraryConnectionOption>

    suspend fun book(bookId: String): Book?

    suspend fun bookDetail(book: Book): Book?

    fun bookFlow(bookId: String): Flow<Book?>

    fun bookByKeyFlow(bookKey: String): Flow<Book?>

    suspend fun linkedAudiobook(book: Book): Book?

    suspend fun linkedEbook(book: Book): Book?

    suspend fun linkCandidates(book: Book, query: String = ""): List<LibraryLinkCandidate>

    suspend fun linkEditions(book: Book, counterpart: Book): Boolean

    suspend fun unlinkEditions(book: Book): Boolean

    val isRefreshing: StateFlow<Boolean>

    suspend fun refresh()

    val hiddenBookIds: Flow<Set<String>>

    suspend fun setFinished(book: Book, finished: Boolean): Boolean
    fun supportsPersonalRating(book: Book): Boolean
    suspend fun setPersonalRating(book: Book, rating: Int): Boolean
    suspend fun setHidden(bookId: String, hidden: Boolean)

    fun downloadState(bookId: String): Flow<LibraryDownloadState>
    suspend fun download(book: Book)
    suspend fun removeDownload(book: Book)
    suspend fun resetProgress(book: Book)
    suspend fun supportsMetadataEdit(book: Book): Boolean
    suspend fun updateMetadata(book: Book, metadata: LibraryMetadataEdit): Book?
    fun defaultMetadataMatchQuery(book: Book): String
    suspend fun searchMetadataMatches(book: Book, query: String): List<LibraryMetadataMatch>
    suspend fun applyMetadataMatch(book: Book, match: LibraryMetadataMatch): Book?
    suspend fun deleteFromLibrary(book: Book): Boolean
    suspend fun separateAudiobookChapter(book: Book, chapter: Chapter): Boolean

    suspend fun chapters(book: Book, forceEmbedded: Boolean = false): List<Chapter>?
}
