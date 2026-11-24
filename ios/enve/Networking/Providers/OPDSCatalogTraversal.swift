import Foundation

struct OPDSCatalogContext {
    let providerId: UUID
    let libraryId: String
    /// Keys progression discovery to a configured connection; it does not restrict service hosts.
    var credentialOrigin: URL?

    var isConnected: Bool { credentialOrigin != nil }
}

struct OPDSFeedDocument {
    let url: URL
    let contentType: String
    let data: Data
}

// MARK: - Browsable catalog surface

/// An entry of a feed's `navigation` collection, or an OPDS 1 entry whose only link leads to a sub-feed.
struct OPDSNavigationEntry: Identifiable, Hashable {
    let title: String
    let summary: String?
    let url: URL
    let count: Int?

    var id: String { url.absoluteString }
}

struct OPDSWebCatalog: Identifiable, Hashable {
    let title: String
    let summary: String?
    let url: URL

    var id: String { url.absoluteString }
}

/// One alternative view of the collection being browsed — a language, a sort order, an availability.
struct OPDSFacet: Identifiable, Hashable {
    let title: String
    let url: URL
    let count: Int?
    let isActive: Bool

    var id: String { url.absoluteString }
}

struct OPDSFacetGroup: Identifiable {
    let title: String
    let facets: [OPDSFacet]

    var id: String { title + (facets.first?.id ?? "") }
}

/// A `catalogs` member: another catalog this one points at, which is navigation rather than a publication.
struct OPDSCatalogReference: Identifiable {
    let title: String
    let summary: String?
    let url: URL

    var id: String { url.absoluteString }
}

/// A `groups` member: a preview of a collection, alongside the link to the rest of it.
struct OPDSCatalogGroup: Identifiable {
    let title: String
    let url: URL?
    let navigation: [OPDSNavigationEntry]
    let webCatalogs: [OPDSWebCatalog]
    let publications: [OPDSPublicationEntry]

    var id: String { url?.absoluteString ?? title }
}

/// Pagination continues the current collection; navigation descends into another collection.
struct OPDSPagination: Equatable {
    var first: URL?
    var previous: URL?
    var next: URL?
    var last: URL?
    var currentPage: Int?
    var numberOfItems: Int?
    var itemsPerPage: Int?

    var hasPages: Bool { first != nil || previous != nil || next != nil || last != nil }
}

/// OPDS 2 supplies a URI template; OPDS 1 may require fetching an OpenSearch description.
struct OPDSSearchDescriptor: Equatable {
    enum Kind: Equatable {
        case template(String)
        case openSearchDescription(URL)
    }

    let kind: Kind
    let title: String?

    /// Returns nil for unresolved descriptions or unsafe expanded URLs.
    func url(forTerms terms: String) -> URL? {
        guard case .template(let template) = kind else { return nil }
        return OPDSURITemplate
            .expand(template, values: Self.values(forTerms: terms, in: template))
            .flatMap(URL.init(string:))
            .flatMap { OPDSURL.isRequestable($0) ? $0 : nil }
    }

    /// Accept common search-variable aliases and default pagination variables to the first page.
    static func values(forTerms terms: String, in template: String) -> [String: String] {
        var values: [String: String] = [:]
        for name in OPDSURITemplate.variableNames(in: template) {
            switch name.split(separator: ":").last.map(String.init)?.lowercased() ?? "" {
            case "searchterms", "query", "q", "keywords", "search", "term", "terms", "title":
                values[name] = terms
            case "startindex": values[name] = "1"
            case "startpage", "page": values[name] = "1"
            case "count", "pagesize", "itemsperpage": values[name] = "50"
            case "language": values[name] = Locale.preferredLanguages.first ?? "*"
            case "inputencoding", "outputencoding": values[name] = "UTF-8"
            default: break
            }
        }
        return values
    }
}

/// Includes publications with no supported acquisition so the browser can explain their availability.
struct OPDSPublicationEntry: Identifiable {
    /// Acquisition URLs may contain expiring tokens, so use them as identity only as a last resort.
    let identity: String
    /// Server-declared identifier used to match rejected content.
    let declaredIdentifier: String?
    let title: String
    let authors: [String]
    let narrators: [String]
    let summary: String?
    let seriesInfo: SeriesInfo?
    let languages: [String]
    let publishedYear: Int?
    let duration: TimeInterval?
    let modified: Date?
    let coverURL: URL?
    let thumbnailURL: URL?
    /// The publication's own document, when the feed named one.
    let detailURL: URL?
    /// Every acquisition the entry offers, most permissive first.
    let acquisitions: [OPDSAcquisition]
    let progression: OPDSProgressionEndpoint?
    /// The book Enve imports, and `nil` when nothing here delivers a file it can open.
    let book: Book?
    /// Why nothing here can be opened, for the rejected-content surface and for the row in the browser.
    let unavailableReason: String?

    var id: String { identity }

    var fulfillable: OPDSAcquisition? { acquisitions.first(where: OPDSAcquisitionSelector.isDownloadable) }

    /// An acquisition the reader completes somewhere else: a purchase, a loan, a subscription.
    var transactions: [OPDSAcquisition] {
        acquisitions.filter { $0.kind.isTransaction }
    }

    /// Samples require explicit selection and never replace the full publication during import.
    var sample: OPDSAcquisition? {
        preview.flatMap { OPDSAcquisitionSelector.undeliverableReason(for: $0) == nil ? $0 : nil }
    }

    var unavailableSampleReason: String? {
        preview.flatMap(OPDSAcquisitionSelector.undeliverableReason)
    }

    private var preview: OPDSAcquisition? { acquisitions.first { $0.kind == .preview } }

    var rejection: RejectedContentCandidate? {
        guard let unavailableReason else { return nil }
        return RejectedContentCandidate(
            itemIdentifier: declaredIdentifier,
            title: title,
            reason: unavailableReason,
            fallbackIdentifier: detailURL?.absoluteString ?? title
        )
    }

    var authorText: String? { authors.isEmpty ? nil : authors.joined(separator: ", ") }
}

struct OPDSCatalogPage {
    let url: URL
    var title: String?
    var summary: String?
    var navigation: [OPDSNavigationEntry] = []
    var groups: [OPDSCatalogGroup] = []
    var facetGroups: [OPDSFacetGroup] = []
    var catalogs: [OPDSCatalogReference] = []
    var webCatalogs: [OPDSWebCatalog] = []
    var publications: [OPDSPublicationEntry] = []
    var pagination = OPDSPagination()
    var search: OPDSSearchDescriptor?
    /// An OPDS Authentication Document the feed named, so a reader can sign in before provoking a `401`.
    var authenticationDocumentURL: URL?

    /// Include group members in import; some feeds list publications only inside groups.
    var allPublications: [OPDSPublicationEntry] { publications + groups.flatMap(\.publications) }
}

/// Retains both the browsable structure and the books used for reconciliation.
struct OPDSParsedFeed {
    var page: OPDSCatalogPage
    /// Child collections the import descends into.
    var navigationTargets: [URL] = []
    /// Items the source sent that could not be decoded at all, which is data loss rather than a refusal.
    var undecodable: [RejectedContentCandidate] = []
    /// False only when the page itself lost data. A deliberate, repeatable skip leaves this true.
    var isComplete = true

    init(page: OPDSCatalogPage) {
        self.page = page
    }

    var books: [Book] { page.allPublications.compactMap(\.book) }

    var nextPage: URL? { page.pagination.next }

    /// Entries the source returned that Enve could not turn into a book, for the rejected-content surface.
    var rejected: [RejectedContentCandidate] {
        undecodable + page.allPublications.compactMap(\.rejection)
    }

    /// Progression services the page advertised, keyed by the stable ID of the book that carries them.
    var progressionEndpoints: [String: OPDSProgressionEndpoint] {
        var endpoints: [String: OPDSProgressionEndpoint] = [:]
        for entry in page.allPublications {
            guard let book = entry.book, let progression = entry.progression else { continue }
            endpoints[book.stableId] = progression
        }
        return endpoints
    }
}

struct OPDSCatalogTraversal {
    /// Traversal limits mark snapshots incomplete rather than silently truncating the library.
    struct Limits {
        var navigationDepth = 10
        var navigationLinksPerFeed = 200
        var pagesPerFeed = 2000
        var feedRequests = 5000
    }

    struct Result {
        var books: [Book] = []
        var rejected: [RejectedContentCandidate] = []
        var progressionEndpoints: [String: OPDSProgressionEndpoint] = [:]
        var notices: [String] = []
        /// Reconciliation deletes books it no longer sees, so an incomplete snapshot must never be trusted.
        var isComplete = true
        var root: OPDSCatalogPage?

        mutating func markPartial(_ notice: String) {
            isComplete = false
            if !notices.contains(notice) { notices.append(notice) }
        }
    }

    let context: OPDSCatalogContext
    var limits = Limits()
    let load: @MainActor (URL) async throws -> OPDSFeedDocument

    func collect(from root: URL) async throws -> Result {
        var result = Result()
        var seen: Set<String> = [Self.identity(of: root)]
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var requestsRemaining = limits.feedRequests
        var cursor = 0

        while cursor < queue.count {
            let entry = queue[cursor]
            cursor += 1

            var pageURL: URL? = entry.url
            var pagesRead = 0

            while let current = pageURL {
                guard requestsRemaining > 0 else {
                    result.markPartial("Stopped after \(limits.feedRequests) feed requests.")
                    return Self.deduplicatingBooks(in: result)
                }
                let isRootRequest = requestsRemaining == limits.feedRequests
                requestsRemaining -= 1

                let page: OPDSParsedFeed
                do {
                    let document = try await load(current)
                    page = try OPDSFeedParser.parse(document: document, context: context)
                } catch {
                    // Only root failures abort import; deeper failures mark it incomplete to prevent deletions.
                    guard !isRootRequest else { throw error }
                    result.markPartial(
                        pagesRead == 0
                            ? "A sub-feed at navigation depth \(entry.depth) could not be read."
                            : "A continuation page at navigation depth \(entry.depth) could not be read."
                    )
                    break
                }

                if isRootRequest { result.root = page.page }
                result.books.append(contentsOf: page.books)
                result.rejected.append(contentsOf: page.rejected)
                result.progressionEndpoints.merge(page.progressionEndpoints) { existing, _ in existing }
                if !page.isComplete {
                    result.markPartial("A feed page contained entries that could not be decoded.")
                }

                if entry.depth < limits.navigationDepth {
                    if page.navigationTargets.count > limits.navigationLinksPerFeed {
                        result.markPartial(
                            "A feed offered more than \(limits.navigationLinksPerFeed) navigation links; the remainder were not followed."
                        )
                    }
                    for target in page.navigationTargets.prefix(limits.navigationLinksPerFeed) {
                        if seen.insert(Self.identity(of: target)).inserted {
                            queue.append((target, entry.depth + 1))
                        }
                    }
                } else if !page.navigationTargets.isEmpty {
                    result.markPartial("Navigation depth \(limits.navigationDepth) reached; deeper sub-feeds were not visited.")
                }

                pagesRead += 1
                guard let next = page.nextPage else { break }
                guard pagesRead < limits.pagesPerFeed else {
                    result.markPartial("Stopped after \(limits.pagesPerFeed) pages within a single feed.")
                    break
                }
                guard seen.insert(Self.identity(of: next)).inserted else { break }
                pageURL = next
            }
        }

        return Self.deduplicatingBooks(in: result)
    }

    /// Fragments never change what a server returns, so they must not defeat cycle detection.
    static func identity(of url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return (components?.url ?? url).absoluteString
    }

    private static func deduplicatingBooks(in result: Result) -> Result {
        var deduplicated = result
        var seen = Set<String>()
        deduplicated.books = result.books.filter { seen.insert($0.uniqueId).inserted }
        return deduplicated
    }
}
