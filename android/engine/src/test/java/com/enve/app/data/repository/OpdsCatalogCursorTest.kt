package com.enve.app.data.repository

import com.enve.core.data.model.BookSummary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsCatalogCursorTest {

    private val root = "https://opds.example.com/root"

    private fun url(path: String) =
        if (path.startsWith("http")) path else "https://opds.example.com/$path"

    private fun publication(id: String) = OpdsPublication(
        id = id,
        identifier = id,
        selfUrl = null,
        summary = BookSummary(id = id, connectionId = "c", title = id),
        acquisitions = emptyList(),
        selectedAcquisition = null,
    )

    private fun page(
        navigation: List<String> = emptyList(),
        next: String? = null,
        publicationCount: Int = 0,
        navigationType: String = "application/opds+json",
    ) = OpdsFeedParser.ParsedPage(
        items = emptyList(),
        nextUrl = next?.let(::url),
        navigationLinks = navigation.map {
            OpdsFeedParser.NavigationLink(title = it, href = url(it), rel = "subsection", type = navigationType)
        },
        publications = List(publicationCount) { publication("$it") },
    )

    @Test
    fun finishes_paginating_a_branch_before_moving_to_the_next_branch() {
        val cursor = OpdsCatalogCursor(root)

        assertEquals(root, cursor.peekFetch())
        assertFalse(cursor.accept(page(navigation = listOf("a", "b"))))
        assertEquals(0, cursor.documentCount)

        assertEquals(url("a"), cursor.peekFetch())
        assertTrue(cursor.accept(page(next = "a2", publicationCount = 2)))
        assertEquals(url("a2"), cursor.peekFetch())
        assertTrue(cursor.accept(page(publicationCount = 1)))

        assertEquals(url("b"), cursor.peekFetch())
        assertTrue(cursor.accept(page(publicationCount = 1)))

        assertNull(cursor.peekFetch())
        assertEquals(
            listOf("a", "a2", "b").map(::url),
            (0 until cursor.documentCount).map { cursor.documentUrlAt(it) },
        )
        assertFalse(cursor.truncated)
    }

    @Test
    fun pagination_is_independent_of_navigation_depth() {
        val cursor = OpdsCatalogCursor(root, maxNavigationDepth = 1)

        cursor.accept(page(navigation = listOf("a")))
        assertEquals(url("a"), cursor.peekFetch())
        cursor.accept(page(next = "a2", publicationCount = 1))
        assertEquals(url("a2"), cursor.peekFetch())
        cursor.accept(page(next = "a3", publicationCount = 1))
        assertEquals(url("a3"), cursor.peekFetch())
        cursor.accept(page(publicationCount = 1))

        assertEquals(3, cursor.documentCount)
        assertFalse(cursor.truncated)
    }

    @Test
    fun navigation_beyond_the_depth_limit_marks_the_catalog_truncated() {
        val cursor = OpdsCatalogCursor(root, maxNavigationDepth = 1)

        cursor.accept(page(navigation = listOf("a")))
        cursor.accept(page(navigation = listOf("deep")))

        assertNull(cursor.peekFetch())
        assertTrue(cursor.truncated)
    }

    @Test
    fun a_single_visited_set_is_shared_across_branches() {
        val cursor = OpdsCatalogCursor(root)

        cursor.accept(page(navigation = listOf("a", "b")))
        assertEquals(url("a"), cursor.peekFetch())
        cursor.accept(page(navigation = listOf("b", root)))
        assertEquals(url("b"), cursor.peekFetch())
        cursor.accept(page(navigation = listOf("a", root)))

        assertNull(cursor.peekFetch())
        assertEquals(0, cursor.documentCount)
        assertFalse(cursor.truncated)
    }

    @Test
    fun a_repeated_next_link_does_not_loop_forever() {
        val cursor = OpdsCatalogCursor(root)

        assertTrue(cursor.accept(page(next = "page2", publicationCount = 1)))
        assertEquals(url("page2"), cursor.peekFetch())
        assertTrue(cursor.accept(page(next = "page2", publicationCount = 1)))

        assertNull(cursor.peekFetch())
        assertEquals(2, cursor.documentCount)
    }

    @Test
    fun a_failed_branch_marks_the_catalog_truncated() {
        val cursor = OpdsCatalogCursor(root)

        cursor.accept(page(navigation = listOf("a", "b")))
        assertEquals(url("a"), cursor.peekFetch())
        cursor.markFailed()

        assertTrue(cursor.truncated)
        assertEquals(url("b"), cursor.peekFetch())
    }

    @Test
    fun navigation_links_that_are_not_feeds_are_never_traversed() {
        val cursor = OpdsCatalogCursor(root)

        cursor.accept(page(navigation = listOf("help"), navigationType = "text/html"))

        assertNull(cursor.peekFetch())
        assertFalse(cursor.truncated)
    }

    @Test
    fun the_branch_budget_bounds_the_crawl_and_reports_truncation() {
        val cursor = OpdsCatalogCursor(root, maxNavigationFetches = 3)

        cursor.accept(page(navigation = listOf("a", "b", "c", "d", "e")))

        assertTrue(cursor.truncated)
        assertEquals(url("a"), cursor.peekFetch())
        cursor.accept(page(publicationCount = 1))
        cursor.accept(page(publicationCount = 1))
        assertNull(cursor.peekFetch())
        assertEquals(2, cursor.documentCount)
    }

    @Test
    fun a_link_dropped_for_budget_is_still_reachable_as_a_pagination_link() {
        val cursor = OpdsCatalogCursor(root, maxNavigationFetches = 2)

        cursor.accept(page(navigation = listOf("a", "b")))
        assertTrue(cursor.truncated)
        assertEquals(url("a"), cursor.peekFetch())

        cursor.accept(page(next = "b", publicationCount = 1))

        assertEquals(url("b"), cursor.peekFetch())
    }

    @Test
    fun cross_origin_catalog_links_are_never_traversed() {
        val cursor = OpdsCatalogCursor(root)

        cursor.accept(
            page(navigation = listOf("https://evil.example.org/catalog", "https://opds.example.com/fiction"))
        )

        assertEquals("https://opds.example.com/fiction", cursor.peekFetch())
        cursor.accept(page(publicationCount = 1))
        assertNull(cursor.peekFetch())
        assertFalse(cursor.truncated)
    }

    @Test
    fun a_link_this_app_cannot_resolve_to_an_origin_is_never_traversed() {
        val cursor = OpdsCatalogCursor(root)

        cursor.accept(
            OpdsFeedParser.ParsedPage(
                items = emptyList(),
                nextUrl = "//evil.example.org/page2",
                navigationLinks = listOf("/fiction", "not a url").map {
                    OpdsFeedParser.NavigationLink(title = it, href = it, rel = "subsection", type = "application/opds+json")
                },
            )
        )

        assertNull(cursor.peekFetch())
    }

    @Test
    fun a_pagination_link_on_a_non_default_port_is_a_different_origin() {
        val cursor = OpdsCatalogCursor(root)

        cursor.accept(page(next = "https://opds.example.com:8443/page2", publicationCount = 1))

        assertNull(cursor.peekFetch())
    }

    @Test
    fun the_default_port_spelling_is_still_the_same_origin() {
        val cursor = OpdsCatalogCursor(root)

        cursor.accept(page(next = "https://opds.example.com:443/page2", publicationCount = 1))

        assertEquals("https://opds.example.com:443/page2", cursor.peekFetch())
    }

    @Test
    fun a_cross_origin_pagination_link_is_not_followed() {
        val cursor = OpdsCatalogCursor(root)

        cursor.accept(page(next = "https://cdn.example.org/page2", publicationCount = 1))

        assertNull(cursor.peekFetch())
    }

    @Test
    fun the_document_cap_stops_the_crawl_and_reports_truncation() {
        val cursor = OpdsCatalogCursor(root, maxDocuments = 2)

        assertTrue(cursor.accept(page(next = "page2", publicationCount = 1)))
        assertTrue(cursor.accept(page(next = "page3", publicationCount = 1)))

        assertNull(cursor.peekFetch())
        assertEquals(2, cursor.documentCount)
        assertTrue(cursor.truncated)
    }

    @Test
    fun the_book_cap_stops_the_crawl_and_reports_truncation() {
        val cursor = OpdsCatalogCursor(root, maxBooks = 3)

        assertTrue(cursor.accept(page(next = "page2", publicationCount = 3)))

        assertNull(cursor.peekFetch())
        assertEquals(1, cursor.documentCount)
        assertTrue(cursor.truncated)
    }

    @Test
    fun the_pagination_cap_bounds_a_single_branch() {
        val cursor = OpdsCatalogCursor(root, maxPaginationPages = 2)

        assertTrue(cursor.accept(page(next = "page2", publicationCount = 1)))
        assertEquals(url("page2"), cursor.peekFetch())
        assertTrue(cursor.accept(page(next = "page3", publicationCount = 1)))

        assertNull(cursor.peekFetch())
        assertTrue(cursor.truncated)
    }

    @Test
    fun hasMoreAfter_reports_pending_branches_and_later_documents() {
        val cursor = OpdsCatalogCursor(root)

        cursor.accept(page(navigation = listOf("a", "b")))
        cursor.accept(page(publicationCount = 1))
        assertTrue(cursor.hasMoreAfter(0))

        cursor.accept(page(publicationCount = 1))
        assertEquals(2, cursor.documentCount)
        assertTrue(cursor.hasMoreAfter(0))
        assertFalse(cursor.hasMoreAfter(1))
    }
}
