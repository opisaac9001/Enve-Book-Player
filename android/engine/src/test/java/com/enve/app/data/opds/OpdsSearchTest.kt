package com.enve.app.data.opds

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsSearchTest {

    private val baseUrl = "https://opds.example.com/opensearch.xml"

    @Test
    fun an_opds2_form_style_template_becomes_a_query_string() {
        assertEquals(
            "https://opds.example.com/search?query=jane%20eyre",
            expandOpdsSearchTemplate("https://opds.example.com/search{?query}", "jane eyre"),
        )
        assertEquals(
            "https://opds.example.com/search?query=verne",
            expandOpdsSearchTemplate("https://opds.example.com/search{?query,author,title}", "verne"),
        )
    }

    @Test
    fun an_opensearch_template_substitutes_search_terms_and_drops_the_rest() {
        assertEquals(
            "https://opds.example.com/search?q=jane%20eyre&start=&count=",
            expandOpdsSearchTemplate(
                "https://opds.example.com/search?q={searchTerms}&start={startIndex?}&count={count?}",
                "jane eyre",
            ),
        )
    }

    @Test
    fun a_namespaced_variable_is_matched_on_its_local_name() {
        assertEquals(
            "https://opds.example.com/s?title=dune",
            expandOpdsSearchTemplate("https://opds.example.com/s{?atom:title}", "dune"),
        )
        assertEquals(
            "https://opds.example.com/s?",
            expandOpdsSearchTemplate("https://opds.example.com/s?{?atom:author}", "dune"),
        )
    }

    @Test
    fun a_template_with_no_search_variable_is_left_without_a_term() {
        assertEquals(
            "https://opds.example.com/search",
            expandOpdsSearchTemplate("https://opds.example.com/search{?page}", "dune"),
        )
    }

    @Test
    fun an_unterminated_expression_is_copied_verbatim() {
        assertEquals(
            "https://opds.example.com/search{?query",
            expandOpdsSearchTemplate("https://opds.example.com/search{?query", "dune"),
        )
    }

    @Test
    fun an_opensearch_description_yields_the_opds_template() {
        val template = parseOpenSearchTemplate(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
              <ShortName>Example</ShortName>
              <Url type="text/html" template="https://opds.example.com/html?q={searchTerms}"/>
              <Url type="application/atom+xml;profile=opds-catalog"
                   template="/search?q={searchTerms}"/>
            </OpenSearchDescription>
            """.trimIndent(),
            baseUrl,
        )

        assertEquals("https://opds.example.com/search?q={searchTerms}", template)
    }

    @Test
    fun a_description_without_a_url_element_has_no_template() {
        assertNull(parseOpenSearchTemplate("<OpenSearchDescription/>", baseUrl))
        assertNull(parseOpenSearchTemplate("not xml at all", baseUrl))
    }

    @Test
    fun the_opensearch_media_type_is_recognised_with_parameters() {
        assertTrue(isOpenSearchDescription("application/opensearchdescription+xml"))
        assertTrue(isOpenSearchDescription("application/opensearchdescription+xml; charset=utf-8"))
        assertFalse(isOpenSearchDescription("application/opds+json"))
    }
}
