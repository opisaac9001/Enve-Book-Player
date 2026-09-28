import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSSearchDescriptorTests {
    private let base = URL(string: "https://catalog.example.invalid/opds/root.json")!

    // MARK: URI templates

    @Test func aQueryExpressionBecomesAQueryString() {
        #expect(
            OPDSURITemplate.expand("https://c.invalid/search{?query}", values: ["query": "harbour"])
                == "https://c.invalid/search?query=harbour"
        )
    }

    @Test func aBarePlaceholderIsReplacedInPlace() {
        #expect(
            OPDSURITemplate.expand("https://c.invalid/search?q={searchTerms}", values: ["searchTerms": "quiet harbours"])
                == "https://c.invalid/search?q=quiet%20harbours"
        )
    }

    @Test func severalVariablesShareOneQueryExpression() {
        #expect(
            OPDSURITemplate.expand("https://c.invalid/s{?query,page}", values: ["query": "a", "page": "2"])
                == "https://c.invalid/s?query=a&page=2"
        )
    }

    /// RFC 6570 drops an expression whose variables are all undefined, which is also what OpenSearch's
    /// `{name?}` optional marker means.
    @Test func anUndefinedVariableLeavesNothingBehind() {
        #expect(
            OPDSURITemplate.expand("https://c.invalid/s?q={searchTerms}&c={count?}", values: ["searchTerms": "a"])
                == "https://c.invalid/s?q=a&c="
        )
        #expect(
            OPDSURITemplate.expand("https://c.invalid/s{?query,unknown}", values: ["query": "a"])
                == "https://c.invalid/s?query=a"
        )
    }

    @Test func aNamespacedOpenSearchVariableIsFilledByItsLocalName() {
        #expect(
            OPDSURITemplate.expand("https://c.invalid/s?i={atom:startIndex}", values: ["startIndex": "1"])
                == "https://c.invalid/s?i=1"
        )
    }

    @Test func anUnclosedExpressionIsRefused() {
        #expect(OPDSURITemplate.expand("https://c.invalid/s{?query", values: ["query": "a"]) == nil)
    }

    @Test func aTemplateWithNoExpressionExpandsToItself() {
        #expect(OPDSURITemplate.expand("https://c.invalid/s", values: [:]) == "https://c.invalid/s")
        #expect(!OPDSURITemplate.isTemplated("https://c.invalid/s"))
        #expect(OPDSURITemplate.isTemplated("https://c.invalid/s{?query}"))
    }

    @Test func everyVariableIsReported() {
        #expect(OPDSURITemplate.variableNames(in: "/s{?query,page}#{frag}") == ["query", "page", "frag"])
        #expect(OPDSURITemplate.variableNames(in: "/s?q={searchTerms}&n={count?}") == ["searchTerms", "count"])
    }

    // MARK: Descriptor

    @Test func aTemplatedSearchLinkIsResolvedAgainstTheFeed() throws {
        let descriptor = try #require(
            OPDSFeedParser.searchDescriptor(
                in: [OPDSLink(href: "/opds/v2/search.json{?query}", type: "application/opds+json", rels: ["search"], templated: true)],
                baseURL: base
            )
        )

        #expect(
            descriptor.url(forTerms: "harbour")?.absoluteString
                == "https://catalog.example.invalid/opds/v2/search.json?query=harbour"
        )
    }

    @Test func anUntemplatedSearchLinkNeedsItsOpenSearchDescription() throws {
        let descriptor = try #require(
            OPDSFeedParser.searchDescriptor(
                in: [
                    OPDSLink(
                        href: "/opds/v1/opensearch.xml",
                        type: "application/opensearchdescription+xml",
                        rels: ["search"],
                        title: "Search the lab catalogue"
                    )
                ],
                baseURL: base
            )
        )

        #expect(descriptor.kind == .openSearchDescription(URL(string: "https://catalog.example.invalid/opds/v1/opensearch.xml")!))
        #expect(descriptor.url(forTerms: "harbour") == nil)
        #expect(descriptor.title == "Search the lab catalogue")
    }

    /// An OPDS 1 feed often puts the template on the link itself, without declaring it templated.
    @Test func aBracedHrefIsATemplateEvenWhenTheLinkDoesNotSaySo() throws {
        let descriptor = try #require(
            OPDSFeedParser.searchDescriptor(
                in: [OPDSLink(href: "/opds/search?q={searchTerms}", type: "application/atom+xml", rels: ["search"])],
                baseURL: base
            )
        )

        #expect(
            descriptor.url(forTerms: "quiet")?.absoluteString
                == "https://catalog.example.invalid/opds/search?q=quiet"
        )
    }

    @Test func aFeedWithNoSearchLinkHasNoSearch() {
        #expect(OPDSFeedParser.searchDescriptor(in: [OPDSLink(href: "/opds/root.json", rels: ["self"])], baseURL: base) == nil)
    }

    // MARK: OpenSearch descriptions

    private static let openSearch = """
        <?xml version="1.0" encoding="UTF-8"?>
        <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
          <ShortName>Enve OPDS Lab</ShortName>
          <Url type="application/atom+xml;profile=opds-catalog;kind=acquisition"
               template="https://catalog.example.invalid/opds/v1/search.xml?q={searchTerms}"/>
          <Url type="application/opds+json"
               template="https://catalog.example.invalid/opds/v2/search.json?query={searchTerms}"/>
        </OpenSearchDescription>
        """

    /// Both templates work; the JSON one is the richer feed, so it wins.
    @Test func theOPDS2TemplateIsPreferred() throws {
        let descriptor = try #require(
            OPDSOpenSearchDescription.searchDescriptor(
                in: Data(Self.openSearch.utf8),
                baseURL: base,
                title: nil
            )
        )

        #expect(
            descriptor.url(forTerms: "harbour")?.absoluteString
                == "https://catalog.example.invalid/opds/v2/search.json?query=harbour"
        )
        #expect(descriptor.title == "Enve OPDS Lab")
    }

    @Test func aRelativeOpenSearchTemplateIsMadeAbsolute() throws {
        let descriptor = try #require(
            OPDSOpenSearchDescription.searchDescriptor(
                in: Data(
                    """
                    <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
                      <Url type="application/atom+xml" template="/opds/search?q={searchTerms}"/>
                    </OpenSearchDescription>
                    """.utf8
                ),
                baseURL: URL(string: "https://catalog.example.invalid/opds/v1/opensearch.xml")!,
                title: nil
            )
        )

        #expect(
            descriptor.url(forTerms: "a")?.absoluteString == "https://catalog.example.invalid/opds/search?q=a"
        )
    }

    @Test func aDescriptionWithNoUsableTemplateYieldsNothing() {
        #expect(
            OPDSOpenSearchDescription.searchDescriptor(
                in: Data("<OpenSearchDescription><ShortName>X</ShortName></OpenSearchDescription>".utf8),
                baseURL: base,
                title: nil
            ) == nil
        )
        #expect(
            OPDSOpenSearchDescription.searchDescriptor(in: Data("not xml at all <".utf8), baseURL: base, title: nil) == nil
        )
    }

    // MARK: Variable naming

    @Test(arguments: ["query", "searchTerms", "q", "keywords", "title"])
    func everyCommonSearchVariableGetsTheTerms(name: String) {
        let values = OPDSSearchDescriptor.values(forTerms: "harbour", in: "/s{?\(name)}")

        #expect(values[name] == "harbour")
    }

    @Test func aPagingVariableAsksForTheFirstPage() {
        let values = OPDSSearchDescriptor.values(forTerms: "a", in: "/s{?query,startIndex,count}")

        #expect(values["startIndex"] == "1")
        #expect(values["count"] == "50")
    }
}
