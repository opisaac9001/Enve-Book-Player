package com.enve.app.hearth

import com.enve.app.data.discover.DiscoverLibraryMatcher
import com.enve.app.data.discover.DiscoverRepository
import com.enve.app.data.discover.DiscoverSectionId
import com.enve.engine.discover.DiscoverBook
import com.enve.engine.discover.DiscoverFacade
import com.enve.engine.discover.DiscoverSection
import com.enve.engine.library.LibraryFacade
import kotlinx.coroutines.flow.first
import javax.inject.Inject

class DiscoverFacadeImpl @Inject constructor(
    private val repository: DiscoverRepository,
    private val library: LibraryFacade,
) : DiscoverFacade {
    override suspend fun load(force: Boolean): List<DiscoverSection> {
        val sections = repository.loadSections(force)
        val matches = DiscoverLibraryMatcher.match(sections, library.allBooks.first())
        return sections.map { section ->
            DiscoverSection(
                id = section.id.name,
                title = if (section.id == DiscoverSectionId.NEW_RELEASES) "Fresh releases" else section.title,
                subtitle = section.subtitle,
                books = section.books.map { book ->
                    DiscoverBook(
                        id = book.id,
                        title = book.title,
                        author = book.author,
                        artworkUrl = book.secureArtworkUrl,
                        description = book.description,
                        publishedDate = book.publishedDate,
                        genre = book.genre,
                        pageCount = book.pageCount,
                        durationMillis = book.durationMillis,
                        infoUrl = book.infoUrl,
                        libraryMatch = matches[book.id],
                    )
                },
            )
        }
    }
}
