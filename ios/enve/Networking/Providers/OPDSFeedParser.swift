import Foundation

enum OPDSFeedParser {
    static func parse(document: OPDSFeedDocument, context: OPDSCatalogContext) throws -> OPDSParsedFeed {
        try requireFeedMediaType(document)
        if isJSONFeed(document) {
            return try parseOPDS2(document: document, context: context)
        }
        return try OPDSAtomParser(document: document, context: context).parse()
    }

    /// Reject non-feed responses before reconciliation can interpret them as an empty catalog.
    private static func requireFeedMediaType(_ document: OPDSFeedDocument) throws {
        let type =
            document.contentType.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        // A server that declares nothing leaves the decision to the body, which both parsers validate.
        guard !type.isEmpty else { return }

        let structured =
            type == "application/json" || type == "application/xml" || type == "text/xml"
            || type.hasSuffix("+json") || type.hasSuffix("+xml") || type.contains("opds")
        guard structured, type != "application/xhtml+xml" else {
            throw ProviderError.serverError("The server answered with \(type) instead of an OPDS feed.")
        }
    }

    static func isJSONFeed(_ document: OPDSFeedDocument) -> Bool {
        for byte in document.data.prefix(64) {
            switch byte {
            case UInt8(ascii: "{"): return true
            case UInt8(ascii: "<"): return false
            case 0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF: continue
            default: return document.contentType.lowercased().contains("json")
            }
        }
        return document.contentType.lowercased().contains("json")
    }

    /// Navigation entries and group self-links are the only places a child collection may be announced.
    static func isNavigable(_ link: OPDSLink) -> Bool {
        !link.rels.contains { OPDSRel.isStructural($0) || OPDSAcquisitionKind(rel: $0) != nil }
    }

    private static func parseOPDS2(document: OPDSFeedDocument, context: OPDSCatalogContext) throws -> OPDSParsedFeed {
        let feed: OPDS2Feed
        do {
            feed = try JSONDecoder().decode(OPDS2Feed.self, from: document.data)
        } catch {
            throw ProviderError.decodingFailed
        }
        guard feed.isRecognizableDocument else {
            throw ProviderError.serverError("The server answered with JSON that is not an OPDS 2 feed.")
        }

        let base = document.url
        var page = OPDSCatalogPage(url: base)
        page.title = feed.metadata?.title
        page.summary = feed.metadata?.subtitle
        var parsed = OPDSParsedFeed(page: page)
        var targets: [URL] = []

        func entries(_ publications: [OPDS2Publication]) -> [OPDSPublicationEntry] {
            publications.map { entry(for: $0, baseURL: base, context: context) }
        }

        // A publication document contains one book; it must not reconcile as an empty catalog.
        if let single = feed.singlePublication {
            parsed.page.publications = entries([single])
        } else {
            parsed.page.publications = entries(feed.publications)
        }
        parsed.undecodable = feed.undecodableItems
        if !feed.undecodableItems.isEmpty { parsed.isComplete = false }

        parsed.page.navigation = navigationEntries(in: feed.navigation, baseURL: base)
        parsed.page.webCatalogs = webCatalogEntries(in: feed.navigation, baseURL: base)
        for catalog in feed.catalogs {
            if let reference = catalogReference(for: catalog, baseURL: base) {
                parsed.page.catalogs.append(reference)
            } else if let webCatalog = webCatalog(for: catalog, baseURL: base) {
                parsed.page.webCatalogs.append(webCatalog)
            }
        }
        parsed.page.facetGroups = facetGroups(in: feed.facets, baseURL: base)

        var groups: [OPDSCatalogGroup] = []
        for group in feed.groups {
            parsed.undecodable.append(contentsOf: group.undecodableItems)
            if !group.undecodableItems.isEmpty { parsed.isComplete = false }
            groups.append(
                OPDSCatalogGroup(
                    title: group.metadata?.title ?? "",
                    // A group only previews its collection; the self link is where the rest of it lives.
                    url: group.links
                        .first { $0.hasRel("self") && OPDSMediaType.isFeed($0.type) && !$0.templated }?
                        .href
                        .flatMap { OPDSURL.resolve($0, baseURL: base) },
                    navigation: navigationEntries(in: group.navigation, baseURL: base),
                    webCatalogs: webCatalogEntries(in: group.navigation, baseURL: base),
                    publications: entries(group.publications)
                )
            )
        }
        parsed.page.groups = groups

        targets.append(contentsOf: parsed.page.navigation.map(\.url))
        targets.append(contentsOf: parsed.page.catalogs.map(\.url))
        for group in parsed.page.groups {
            targets.append(contentsOf: group.navigation.map(\.url))
            if let url = group.url { targets.append(url) }
        }

        parsed.page.pagination = pagination(
            in: feed.links,
            baseURL: base,
            numberOfItems: feed.metadata?.numberOfItems,
            itemsPerPage: feed.metadata?.itemsPerPage,
            currentPage: feed.metadata?.currentPage
        )
        parsed.page.search = searchDescriptor(in: feed.links, baseURL: base)
        parsed.page.authenticationDocumentURL =
            authenticationDocumentURL(in: feed.links, baseURL: base)
            ?? authenticationDocumentURL(inPublications: parsed.page.allPublications, baseURL: base)

        var uniqueTargets = Set<String>()
        parsed.navigationTargets = targets.filter { uniqueTargets.insert($0.absoluteString).inserted }
        return parsed
    }

    // MARK: Shared link readers

    static func url(ofRel rel: String, in links: [OPDSLink], baseURL: URL) -> URL? {
        links
            .first { $0.hasRel(rel) && !$0.templated }?
            .href
            .flatMap { OPDSURL.resolve($0, baseURL: baseURL) }
    }

    static func pagination(
        in links: [OPDSLink],
        baseURL: URL,
        numberOfItems: Int? = nil,
        itemsPerPage: Int? = nil,
        currentPage: Int? = nil
    ) -> OPDSPagination {
        OPDSPagination(
            first: url(ofRel: "first", in: links, baseURL: baseURL),
            previous: url(ofRel: "previous", in: links, baseURL: baseURL)
                ?? url(ofRel: "prev", in: links, baseURL: baseURL),
            next: url(ofRel: "next", in: links, baseURL: baseURL),
            last: url(ofRel: "last", in: links, baseURL: baseURL),
            currentPage: currentPage,
            numberOfItems: numberOfItems,
            itemsPerPage: itemsPerPage
        )
    }

    /// Templated links contain the query; other search links point to an OpenSearch description.
    static func searchDescriptor(in links: [OPDSLink], baseURL: URL) -> OPDSSearchDescriptor? {
        for link in links where link.hasRel("search") {
            guard let href = link.href else { continue }
            if link.templated || OPDSURITemplate.isTemplated(href) {
                // A template is resolved against the feed before expansion, so a relative one still works.
                guard let absolute = OPDSURL.resolveTemplate(href, baseURL: baseURL) else { continue }
                return OPDSSearchDescriptor(kind: .template(absolute), title: link.title)
            }
            guard let url = OPDSURL.resolve(href, baseURL: baseURL) else { continue }
            return OPDSSearchDescriptor(kind: .openSearchDescription(url), title: link.title)
        }
        return nil
    }

    /// A delegated service's authentication document does not describe the catalog connection.
    static func authenticationDocumentURL(
        inPublications publications: [OPDSPublicationEntry],
        baseURL: URL
    ) -> URL? {
        for entry in publications {
            guard let endpoint = entry.progression,
                let hint = endpoint.authenticateURL,
                OPDSURL.sameOrigin(endpoint.url, as: baseURL)
            else { continue }
            return hint
        }
        return nil
    }

    /// Discover sign-in from a direct link or properties.authenticate without requiring a 401.
    static func authenticationDocumentURL(in links: [OPDSLink], baseURL: URL) -> URL? {
        for link in links {
            if let hinted = link.properties?.authenticate?.href,
                let url = OPDSURL.resolve(hinted, baseURL: baseURL)
            {
                return url
            }
            guard !link.templated,
                link.hasRel("http://opds-spec.org/auth/document")
                    || OPDSAuthenticationDocument.isAuthenticationMediaType(link.type),
                let href = link.href,
                let url = OPDSURL.resolve(href, baseURL: baseURL)
            else { continue }
            return url
        }
        return nil
    }

    private static func navigationEntries(in links: [OPDSLink], baseURL: URL) -> [OPDSNavigationEntry] {
        links.compactMap { link in
            guard !link.templated, let href = link.href, isNavigable(link) else { return nil }
            // Navigation entries often omit the type; anything naming a non-feed type is not a collection.
            guard link.type == nil || OPDSMediaType.isFeed(link.type) else { return nil }
            guard let url = OPDSURL.resolve(href, baseURL: baseURL) else { return nil }
            return OPDSNavigationEntry(
                title: link.title ?? url.lastPathComponent,
                summary: nil,
                url: url,
                count: link.properties?.numberOfItems
            )
        }
    }

    private static func webCatalogEntries(in links: [OPDSLink], baseURL: URL) -> [OPDSWebCatalog] {
        links.compactMap { link in
            guard !link.templated,
                let href = link.href,
                isNavigable(link),
                OPDSMediaType.isWebPage(link.type),
                let url = OPDSURL.resolve(href, baseURL: baseURL)
            else { return nil }
            return OPDSWebCatalog(title: link.title ?? url.host ?? url.absoluteString, summary: nil, url: url)
        }
    }

    private static func catalogReference(for entry: OPDS2CatalogEntry, baseURL: URL) -> OPDSCatalogReference? {
        let link = entry.links.first {
            !$0.templated && !OPDSMediaType.isWebPage($0.type)
                && ($0.hasRel("http://opds-spec.org/catalog") || OPDSMediaType.isFeed($0.type))
        }
        guard let url = link?.href.flatMap({ OPDSURL.resolve($0, baseURL: baseURL) }) else { return nil }
        return OPDSCatalogReference(
            title: entry.metadata?.title ?? link?.title ?? url.lastPathComponent,
            summary: entry.metadata?.subtitle,
            url: url
        )
    }

    private static func webCatalog(for entry: OPDS2CatalogEntry, baseURL: URL) -> OPDSWebCatalog? {
        guard let link = webCatalogEntries(in: entry.links, baseURL: baseURL).first else { return nil }
        return OPDSWebCatalog(
            title: entry.metadata?.title ?? link.title,
            summary: entry.metadata?.subtitle,
            url: link.url
        )
    }

    private static func facetGroups(in facets: [OPDS2FacetGroup], baseURL: URL) -> [OPDSFacetGroup] {
        facets.compactMap { group in
            let entries = group.links.compactMap { link -> OPDSFacet? in
                guard !link.templated,
                    let href = link.href,
                    let url = OPDSURL.resolve(href, baseURL: baseURL)
                else { return nil }
                return OPDSFacet(
                    title: link.title ?? url.lastPathComponent,
                    url: url,
                    count: link.properties?.numberOfItems,
                    isActive: false
                )
            }
            guard !entries.isEmpty else { return nil }
            return OPDSFacetGroup(title: group.metadata?.title ?? "", facets: entries)
        }
    }

    // MARK: Publications

    private static func entry(
        for publication: OPDS2Publication,
        baseURL: URL,
        context: OPDSCatalogContext
    ) -> OPDSPublicationEntry {
        let metadata = publication.metadata
        let detailURL =
            publication.links
            .first { $0.hasRel("self") }?
            .href
            .flatMap { OPDSURL.resolve($0, baseURL: baseURL) }

        let acquisitions = OPDSAcquisitionSelector.candidates(in: publication.links, baseURL: baseURL)
        let selection = OPDSAcquisitionSelector.selection(among: acquisitions)

        var seriesInfo: SeriesInfo?
        if let series = metadata.belongsTo?.series.first {
            seriesInfo = SeriesInfo(name: series.name, sequence: series.position.map(OPDSText.position))
        } else if let collection = metadata.belongsTo?.collection.first {
            seriesInfo = SeriesInfo(name: collection.name, sequence: collection.position.map(OPDSText.position))
        }

        let images = publication.images + publication.links.filter { $0.hasAnyRel(OPDSRel.image) }
        let coverURL = OPDSImageLinks.cover(in: images, baseURL: baseURL)
        let authors = metadata.authors.isEmpty ? metadata.translators : metadata.authors
        let publishedYear = metadata.published.flatMap(OPDSText.year)
        // Acquisition URLs routinely carry an expiring token, so they are the last resort for identity.
        let identity =
            metadata.identifier ?? detailURL?.absoluteString
            ?? acquisitions.first?.url.absoluteString ?? metadata.title

        var book: Book?
        var unavailableReason: String?
        switch selection {
        case .downloadable(let acquisition):
            book = Book(
                id: identity,
                title: metadata.title,
                author: authors.isEmpty ? nil : authors.joined(separator: ", "),
                narrator: metadata.narrators.isEmpty ? nil : metadata.narrators.joined(separator: ", "),
                seriesInfo: seriesInfo,
                duration: metadata.duration,
                coverURL: coverURL,
                partKey: acquisition.url.absoluteString,
                mediaType: acquisition.format.mediaType,
                ebookFormat: acquisition.format.ebookFormat?.rawValue,
                description: metadata.description,
                genres: metadata.subjects.isEmpty ? nil : metadata.subjects,
                chapters: [],
                publisher: metadata.publisher,
                progress: 0,
                currentTime: 0,
                isFinished: false,
                lastUpdate: metadata.modified ?? .distantPast,
                libraryId: context.libraryId,
                providerId: context.providerId,
                source: .opds,
                publishedYear: publishedYear,
                language: metadata.languages.first
            )
        case .rejected(let reason), .notAPublication(let reason):
            unavailableReason = reason
        }

        return OPDSPublicationEntry(
            identity: identity,
            declaredIdentifier: metadata.identifier,
            title: metadata.title,
            authors: authors,
            narrators: metadata.narrators,
            summary: metadata.description,
            seriesInfo: seriesInfo,
            languages: metadata.languages,
            publishedYear: publishedYear,
            duration: metadata.duration,
            modified: metadata.modified,
            coverURL: coverURL,
            thumbnailURL: OPDSImageLinks.thumbnail(in: images, baseURL: baseURL),
            detailURL: detailURL,
            acquisitions: acquisitions,
            progression: context.isConnected
                ? OPDSProgressionTransport.endpoint(in: publication.links, baseURL: baseURL)
                : nil,
            book: book,
            unavailableReason: unavailableReason
        )
    }
}

/// Use thumbnails for browser rows and full-size covers for stored books.
enum OPDSImageLinks {
    static func cover(in links: [OPDSLink], baseURL: URL) -> URL? {
        let usable = candidates(in: links)
        let preferred = usable.first { !$0.hasAnyRel(OPDSRel.thumbnail) } ?? usable.first
        return preferred?.href.flatMap { OPDSURL.resolve($0, baseURL: baseURL) }
    }

    static func thumbnail(in links: [OPDSLink], baseURL: URL) -> URL? {
        let usable = candidates(in: links)
        let preferred =
            usable.first { $0.hasAnyRel(OPDSRel.thumbnail) }
            ?? usable.filter { $0.pixelArea != nil }.min { ($0.pixelArea ?? 0) < ($1.pixelArea ?? 0) }
        return preferred?.href.flatMap { OPDSURL.resolve($0, baseURL: baseURL) }
    }

    private static func candidates(in links: [OPDSLink]) -> [OPDSLink] {
        links.filter { !$0.templated && $0.href != nil && !OPDSMediaType.isFeed($0.type) }
    }
}

/// Extract feed query templates from an OPDS 1 OpenSearch description.
enum OPDSOpenSearchDescription {
    static func searchDescriptor(in data: Data, baseURL: URL, title: String?) -> OPDSSearchDescriptor? {
        let parser = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { return nil }

        let ranked = parser.templates.sorted { lhs, rhs in
            rank(of: lhs.type) < rank(of: rhs.type)
        }
        for candidate in ranked {
            guard OPDSURITemplate.isTemplated(candidate.template),
                let absolute = OPDSURL.resolveTemplate(candidate.template, baseURL: baseURL)
            else { continue }
            return OPDSSearchDescriptor(kind: .template(absolute), title: parser.shortName ?? title)
        }
        return nil
    }

    private static func rank(of type: String?) -> Int {
        guard let type = type?.lowercased() else { return 3 }
        if type.contains("opds+json") { return 0 }
        if type.contains("atom+xml") { return 1 }
        return 2
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var templates: [(template: String, type: String?)] = []
        var shortName: String?
        private var currentElement = ""
        private var text = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            currentElement = elementName.contains(":")
                ? String(elementName[elementName.index(after: elementName.lastIndex(of: ":")!)...])
                : elementName
            text = ""
            guard currentElement == "Url", let template = attributes["template"] else { return }
            templates.append((template, attributes["type"]))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            guard currentElement == "ShortName", shortName == nil else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { shortName = trimmed }
        }
    }
}

/// Indirect acquisitions return OPDS entry or publication documents pointing to the next hop.
enum OPDSAcquisitionFulfillment {
    static let hopLimit = 2

    static func isCatalogDocument(_ response: HTTPURLResponse) -> Bool {
        guard let declared = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        else { return false }
        return declared == "application/atom+xml" || declared == "application/opds+json"
            || declared == "application/opds-publication+json"
            || declared == "application/atom+xml;type=entry"
    }

    /// The next URL in the chain, and `nil` when the document names no acquisition Enve can use.
    static func next(
        from data: Data,
        response: HTTPURLResponse,
        requestedURL: URL,
        context: OPDSCatalogContext
    ) -> URL? {
        let document = OPDSFeedDocument(
            url: response.url ?? requestedURL,
            contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "",
            data: data
        )
        guard let parsed = try? OPDSFeedParser.parse(document: document, context: context) else { return nil }
        let candidate = parsed.page.allPublications.compactMap(\.fulfillable).first
        guard let next = candidate?.url, next != requestedURL else { return nil }
        return next
    }
}

private struct OPDS2Feed: Decodable {
    let metadata: OPDS2FeedMetadata?
    let publications: [OPDS2Publication]
    let navigation: [OPDSLink]
    let groups: [OPDS2Group]
    let links: [OPDSLink]
    let catalogs: [OPDS2CatalogEntry]
    let facets: [OPDS2FacetGroup]
    let undecodableItems: [RejectedContentCandidate]
    /// Single-publication documents must import one book rather than reconcile as an empty feed.
    let singlePublication: OPDS2Publication?
    /// Optional fields also decode arbitrary JSON; require metadata and a collection or link.
    let isRecognizableDocument: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try? container.decode(OPDS2FeedMetadata.self, forKey: .metadata)
        let publications = try container.decodeIfPresent(LossyDecodableArray<OPDS2Publication>.self, forKey: .publications)
        self.publications = publications?.values ?? []
        undecodableItems = publications?.rejectedItems ?? []
        navigation = (try? container.decode([OPDSLink].self, forKey: .navigation)) ?? []
        groups = (try? container.decode([OPDS2Group].self, forKey: .groups)) ?? []
        links = (try? container.decode([OPDSLink].self, forKey: .links)) ?? []
        catalogs = (try? container.decode([OPDS2CatalogEntry].self, forKey: .catalogs)) ?? []
        facets = (try? container.decode([OPDS2FacetGroup].self, forKey: .facets)) ?? []

        let collectionKeys: [CodingKeys] = [.publications, .navigation, .groups, .catalogs, .facets]
        let carriesCollection = collectionKeys.contains { container.contains($0) }
        isRecognizableDocument =
            container.contains(.metadata) && (carriesCollection || container.contains(.links))

        // Metadata and links alone can describe an empty collection; require a publication link.
        let declaresPublication = links.contains { link in
            link.rels.contains { OPDSAcquisitionKind(rel: $0) != nil }
                || (link.hasRel("self") && link.type?.lowercased().contains("opds-publication+json") == true)
        }
        singlePublication =
            !carriesCollection && declaresPublication ? try? OPDS2Publication(from: decoder) : nil
    }

    private enum CodingKeys: String, CodingKey {
        case publications, navigation, groups, links, catalogs, metadata, facets
    }
}

private struct OPDS2FeedMetadata: Decodable {
    let title: String?
    let subtitle: String?
    let modified: Date?
    let numberOfItems: Int?
    let itemsPerPage: Int?
    let currentPage: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? OPDS2NamedValue.localizedString(in: container, forKey: .title)
        subtitle = try? OPDS2NamedValue.localizedString(in: container, forKey: .subtitle)
        modified = ISO8601Timestamp.parse(try? container.decode(String.self, forKey: .modified))
        numberOfItems = try? container.decode(Int.self, forKey: .numberOfItems)
        itemsPerPage = try? container.decode(Int.self, forKey: .itemsPerPage)
        currentPage = try? container.decode(Int.self, forKey: .currentPage)
    }

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, modified, numberOfItems, itemsPerPage, currentPage
    }
}

private struct OPDS2Group: Decodable {
    let metadata: OPDS2FeedMetadata?
    let publications: [OPDS2Publication]
    let navigation: [OPDSLink]
    let links: [OPDSLink]
    let undecodableItems: [RejectedContentCandidate]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try? container.decode(OPDS2FeedMetadata.self, forKey: .metadata)
        let publications = try container.decodeIfPresent(LossyDecodableArray<OPDS2Publication>.self, forKey: .publications)
        self.publications = publications?.values ?? []
        undecodableItems = publications?.rejectedItems ?? []
        navigation = (try? container.decode([OPDSLink].self, forKey: .navigation)) ?? []
        links = (try? container.decode([OPDSLink].self, forKey: .links)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case metadata, publications, navigation, links
    }
}

private struct OPDS2FacetGroup: Decodable {
    let metadata: OPDS2FeedMetadata?
    let links: [OPDSLink]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try? container.decode(OPDS2FeedMetadata.self, forKey: .metadata)
        links = (try? container.decode([OPDSLink].self, forKey: .links)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case metadata, links }
}

private struct OPDS2CatalogEntry: Decodable {
    let metadata: OPDS2FeedMetadata?
    let links: [OPDSLink]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try? container.decode(OPDS2FeedMetadata.self, forKey: .metadata)
        links = (try? container.decode([OPDSLink].self, forKey: .links)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case metadata, links }
}

private struct OPDS2Publication: Decodable {
    let metadata: OPDS2Metadata
    let links: [OPDSLink]
    let images: [OPDSLink]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(OPDS2Metadata.self, forKey: .metadata)
        links = (try? container.decode([OPDSLink].self, forKey: .links)) ?? []
        images = (try? container.decode([OPDSLink].self, forKey: .images)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case metadata, links, images }
}

private struct OPDS2Metadata: Decodable {
    let identifier: String?
    let title: String
    let authors: [String]
    let translators: [String]
    let narrators: [String]
    let subjects: [String]
    let publisher: String?
    let description: String?
    let belongsTo: OPDS2BelongsTo?
    let languages: [String]
    let published: String?
    let duration: TimeInterval?
    /// Use the catalog modification date so refreshes do not appear newer than reading progress.
    let modified: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        title = try OPDS2NamedValue.localizedString(in: container, forKey: .title)
        authors = OPDS2NamedValue.names(in: container, forKey: .author)
        translators = OPDS2NamedValue.names(in: container, forKey: .translator)
        narrators = OPDS2NamedValue.names(in: container, forKey: .narrator)
        subjects = OPDS2NamedValue.names(in: container, forKey: .subject)
        publisher = OPDS2NamedValue.names(in: container, forKey: .publisher).first
        description = try container.decodeIfPresent(String.self, forKey: .description)
        belongsTo = try? container.decode(OPDS2BelongsTo.self, forKey: .belongsTo)
        published = try container.decodeIfPresent(String.self, forKey: .published)
        duration = try? container.decode(TimeInterval.self, forKey: .duration)
        modified = ISO8601Timestamp.parse(try? container.decode(String.self, forKey: .modified))

        if let many = try? container.decode([String].self, forKey: .language) {
            languages = many
        } else if let single = try? container.decode(String.self, forKey: .language) {
            languages = [single]
        } else {
            languages = []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case identifier, title, author, translator, narrator, subject, publisher
        case description, belongsTo, language, published, duration, modified
    }
}

private struct OPDS2BelongsTo: Decodable {
    let series: [OPDS2Collection]
    let collection: [OPDS2Collection]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        series = OPDS2Collection.decodeFlexibly(container, forKey: .series)
        collection = OPDS2Collection.decodeFlexibly(container, forKey: .collection)
    }

    private enum CodingKeys: String, CodingKey { case series, collection }
}

private struct OPDS2Collection: Decodable {
    let name: String
    let position: Double?

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            name = text
            position = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try OPDS2NamedValue.localizedString(in: container, forKey: .name)
        position = try container.decodeIfPresent(Double.self, forKey: .position)
    }

    private enum CodingKeys: String, CodingKey { case name, position }

    static func decodeFlexibly<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> [OPDS2Collection] {
        if let many = try? container.decode([OPDS2Collection].self, forKey: key) { return many }
        if let single = try? container.decode(OPDS2Collection.self, forKey: key) { return [single] }
        return []
    }
}

/// Readium names accept strings, name objects, arrays, or language maps.
private enum OPDS2NamedValue {
    static func names<Key: CodingKey>(
        in container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> [String] {
        if let many = try? container.decode([Entry].self, forKey: key) { return many.map(\.name) }
        if let single = try? container.decode(Entry.self, forKey: key) { return [single.name] }
        return []
    }

    static func localizedString<Key: CodingKey>(
        in container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> String {
        if let text = try? container.decode(String.self, forKey: key) { return text }
        let translations = try container.decode([String: String].self, forKey: key)
        guard let selected = OPDSLanguagePreference.select(from: translations) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Localized string had no translations"
            )
        }
        return selected
    }

    private struct Entry: Decodable {
        let name: String

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                name = text
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try OPDS2NamedValue.localizedString(in: container, forKey: .name)
        }

        private enum CodingKeys: String, CodingKey { case name }
    }
}

private final class OPDSAtomParser: NSObject, XMLParserDelegate {
    private struct PendingLink {
        var href: String
        var type: String?
        var rels: [String]
        var title: String?
        var indirectTypes: [String] = []
        var count: Int?
        var isActiveFacet = false
        var facetGroup: String?
        /// OPDS 1.2 carries price, availability, copies and holds as child elements of the link.
        var priceCurrency: String?
        var priceValue: Double?
        var availability: OPDSAvailability?
        var copies: OPDSCopies?
        var holds: OPDSHolds?

        var properties: OPDSLinkProperties? {
            var price: OPDSPrice?
            if let priceCurrency, let priceValue {
                price = OPDSPrice(currency: priceCurrency, value: priceValue)
            }
            guard price != nil || availability != nil || copies != nil || holds != nil || count != nil else {
                return nil
            }
            return OPDSLinkProperties(
                price: price,
                holds: holds,
                copies: copies,
                availability: availability,
                numberOfItems: count
            )
        }
    }

    private struct AtomEntry {
        var id: String?
        var title: String?
        var authors: [String] = []
        var summary: String?
        var links: [OPDSLink] = []
        var seriesName: String?
        var seriesPosition: Double?
        var language: String?
        var publisher: String?
        var issued: String?
        var categories: [String] = []
        var updated: Date?
    }

    private let document: OPDSFeedDocument
    private let context: OPDSCatalogContext

    private var page: OPDSCatalogPage
    private var parsed: OPDSParsedFeed
    private var entry: AtomEntry?
    private var pendingLink: PendingLink?
    private var currentText = ""
    private var insideEntry = false
    private var insideAuthor = false
    private var feedLinks: [OPDSLink] = []
    private var facetLinks: [(group: String, facet: OPDSFacet)] = []
    private var navigationEntries: [OPDSNavigationEntry] = []
    private var rootElement: String?

    init(document: OPDSFeedDocument, context: OPDSCatalogContext) {
        self.document = document
        self.context = context
        page = OPDSCatalogPage(url: document.url)
        parsed = OPDSParsedFeed(page: page)
    }

    /// Malformed or non-OPDS XML must fail before reconciliation can delete books.
    func parse() throws -> OPDSParsedFeed {
        let parser = XMLParser(data: document.data)
        parser.delegate = self
        guard parser.parse() else {
            throw ProviderError.serverError("The server answered with a document that is not well-formed XML.")
        }
        guard let rootElement, rootElement == "feed" || rootElement == "entry" else {
            throw ProviderError.serverError(
                "The XML document is not an OPDS feed; its root element is <\(rootElement ?? "")>."
            )
        }

        page.navigation = navigationEntries
        page.facetGroups = Self.grouped(facetLinks)
        page.pagination = OPDSFeedParser.pagination(in: feedLinks, baseURL: document.url)
        page.search = OPDSFeedParser.searchDescriptor(in: feedLinks, baseURL: document.url)
        page.authenticationDocumentURL =
            OPDSFeedParser.authenticationDocumentURL(in: feedLinks, baseURL: document.url)
            ?? OPDSFeedParser.authenticationDocumentURL(
                inPublications: page.publications,
                baseURL: document.url
            )

        parsed.page = page

        var unique = Set<String>()
        parsed.navigationTargets = navigationEntries
            .map(\.url)
            .filter { unique.insert($0.absoluteString).inserted }
        return parsed
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let name = localName(elementName)
        currentText = ""

        switch name {
        case "entry":
            insideEntry = true
            entry = AtomEntry()
        case "author" where insideEntry:
            insideAuthor = true
        case "indirectAcquisition":
            if let type = attributes["type"] { pendingLink?.indirectTypes.append(type) }
        case "link":
            guard let href = attributes["href"] else { break }
            pendingLink = PendingLink(
                href: href,
                type: attributes["type"],
                rels: (attributes["rel"] ?? "").split(separator: " ").map(String.init),
                title: attributes["title"],
                count: (attributes["thr:count"] ?? attributes["count"]).flatMap { Int($0) },
                isActiveFacet: (attributes["opds:activeFacet"] ?? attributes["activeFacet"]) == "true",
                facetGroup: attributes["opds:facetGroup"] ?? attributes["facetGroup"]
            )
        case "price":
            pendingLink?.priceCurrency = attributes["currencycode"] ?? attributes["currency"]
        case "availability":
            pendingLink?.availability = OPDSAvailability(
                state: attributes["status"] ?? attributes["state"] ?? "unknown",
                since: attributes["since"],
                until: attributes["until"]
            )
        case "copies":
            // Zero is meaningful: every copy is out, which is not the same as an absent attribute.
            pendingLink?.copies = OPDSCopies(
                total: attributes["total"].flatMap { Int($0) },
                available: attributes["available"].flatMap { Int($0) }
            )
        case "holds":
            pendingLink?.holds = OPDSHolds(
                total: attributes["total"].flatMap { Int($0) },
                position: attributes["position"].flatMap { Int($0) }
            )
        case "category" where insideEntry:
            let label = (attributes["label"] ?? attributes["term"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let label, !label.isEmpty { entry?.categories.append(label) }
        case "Series" where insideEntry && isSchemaNamespace(namespaceURI):
            entry?.seriesName = (attributes["schema:name"] ?? attributes["name"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            entry?.seriesPosition = (attributes["schema:position"] ?? attributes["position"]).flatMap { Double($0) }
        default:
            break
        }

        if rootElement == nil { rootElement = name }
    }

    /// With namespace processing disabled, schema:Series is matched by its raw qualified name.
    private func isSchemaNamespace(_ namespaceURI: String?) -> Bool {
        guard let namespaceURI, !namespaceURI.isEmpty else { return true }
        return namespaceURI.contains("schema.org")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let name = localName(elementName)
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "price":
            pendingLink?.priceValue = Double(trimmed)

        case "link":
            guard let pending = pendingLink else { break }
            pendingLink = nil
            let link = OPDSLink(
                href: pending.href,
                type: pending.type,
                rels: pending.rels,
                title: pending.title,
                properties: pending.properties,
                inlineIndirectTypes: pending.indirectTypes
            )
            if insideEntry {
                entry?.links.append(link)
            } else {
                feedLinks.append(link)
                collectFacet(pending)
            }

        case "entry":
            if let entry { finish(entry) }
            self.entry = nil
            insideEntry = false

        case "author":
            insideAuthor = false

        case "title" where !insideEntry:
            if page.title == nil, !trimmed.isEmpty { page.title = trimmed }

        case "subtitle" where !insideEntry:
            if page.summary == nil, !trimmed.isEmpty { page.summary = trimmed }

        default:
            guard insideEntry else { break }
            switch name {
            case "id": entry?.id = trimmed
            case "title": entry?.title = trimmed
            case "updated": entry?.updated = ISO8601Timestamp.parse(trimmed)
            case "language": entry?.language = trimmed.isEmpty ? nil : trimmed
            case "publisher": entry?.publisher = trimmed.isEmpty ? nil : trimmed
            case "issued":
                if entry?.issued == nil, !trimmed.isEmpty { entry?.issued = trimmed }
            case "name" where insideAuthor:
                if !trimmed.isEmpty { entry?.authors.append(trimmed) }
            case "summary", "content":
                if entry?.summary == nil { entry?.summary = trimmed }
            default: break
            }
        }
    }

    private func collectFacet(_ pending: PendingLink) {
        guard pending.rels.contains(where: { $0.lowercased() == "http://opds-spec.org/facet" }),
            let url = OPDSURL.resolve(pending.href, baseURL: document.url)
        else { return }
        facetLinks.append(
            (
                pending.facetGroup ?? "Filter",
                OPDSFacet(
                    title: pending.title ?? url.lastPathComponent,
                    url: url,
                    count: pending.count,
                    isActive: pending.isActiveFacet
                )
            )
        )
    }

    private func finish(_ atomEntry: AtomEntry) {
        let acquisitions = OPDSAcquisitionSelector.candidates(in: atomEntry.links, baseURL: document.url)
        let selection = OPDSAcquisitionSelector.selection(among: acquisitions)

        // An entry with no acquisition at all is how OPDS 1 writes a navigation entry.
        if case .notAPublication = selection, let target = navigationTarget(in: atomEntry.links) {
            navigationEntries.append(
                OPDSNavigationEntry(
                    title: atomEntry.title ?? target.lastPathComponent,
                    summary: atomEntry.summary,
                    url: target,
                    count: nil
                )
            )
            return
        }

        page.publications.append(entry(from: atomEntry, acquisitions: acquisitions, selection: selection))
    }

    private func entry(
        from atomEntry: AtomEntry,
        acquisitions: [OPDSAcquisition],
        selection: OPDSAcquisitionSelection
    ) -> OPDSPublicationEntry {
        let seriesInfo: SeriesInfo? = {
            guard let name = atomEntry.seriesName, !name.isEmpty else { return nil }
            return SeriesInfo(name: name, sequence: atomEntry.seriesPosition.map(OPDSText.position))
        }()

        let images = atomEntry.links.filter { $0.hasAnyRel(OPDSRel.image) }
        let coverURL = OPDSImageLinks.cover(in: images, baseURL: document.url)
        let title = atomEntry.title ?? "Unknown"
        let identity = atomEntry.id ?? acquisitions.first?.url.absoluteString ?? title
        let publishedYear = atomEntry.issued.flatMap(OPDSText.year)

        var book: Book?
        var unavailableReason: String?
        switch selection {
        case .downloadable(let acquisition):
            book = Book(
                id: identity,
                title: title,
                author: atomEntry.authors.isEmpty ? nil : atomEntry.authors.joined(separator: ", "),
                narrator: nil,
                seriesInfo: seriesInfo,
                coverURL: coverURL,
                partKey: acquisition.url.absoluteString,
                mediaType: acquisition.format.mediaType,
                ebookFormat: acquisition.format.ebookFormat?.rawValue,
                description: atomEntry.summary,
                genres: atomEntry.categories.isEmpty ? nil : atomEntry.categories,
                chapters: [],
                publisher: atomEntry.publisher,
                progress: 0,
                currentTime: 0,
                isFinished: false,
                lastUpdate: atomEntry.updated ?? .distantPast,
                libraryId: context.libraryId,
                providerId: context.providerId,
                source: .opds,
                publishedYear: publishedYear,
                language: atomEntry.language
            )
        case .rejected(let reason), .notAPublication(let reason):
            unavailableReason = reason
        }

        return OPDSPublicationEntry(
            identity: identity,
            declaredIdentifier: atomEntry.id,
            title: title,
            authors: atomEntry.authors,
            narrators: [],
            summary: atomEntry.summary,
            seriesInfo: seriesInfo,
            languages: atomEntry.language.map { [$0] } ?? [],
            publishedYear: publishedYear,
            duration: nil,
            modified: atomEntry.updated,
            coverURL: coverURL,
            thumbnailURL: OPDSImageLinks.thumbnail(in: images, baseURL: document.url),
            detailURL: OPDSFeedParser.url(ofRel: "self", in: atomEntry.links, baseURL: document.url),
            acquisitions: acquisitions,
            progression: context.isConnected
                ? OPDSProgressionTransport.endpoint(in: atomEntry.links, baseURL: document.url)
                : nil,
            book: book,
            unavailableReason: unavailableReason
        )
    }

    private func navigationTarget(in links: [OPDSLink]) -> URL? {
        for link in links {
            guard let href = link.href,
                OPDSMediaType.isFeed(link.type),
                OPDSFeedParser.isNavigable(link),
                let url = OPDSURL.resolve(href, baseURL: document.url)
            else { continue }
            return url
        }
        return nil
    }

    private static func grouped(_ facets: [(group: String, facet: OPDSFacet)]) -> [OPDSFacetGroup] {
        var order: [String] = []
        var byGroup: [String: [OPDSFacet]] = [:]
        for (group, facet) in facets {
            if byGroup[group] == nil { order.append(group) }
            byGroup[group, default: []].append(facet)
        }
        return order.map { OPDSFacetGroup(title: $0, facets: byGroup[$0] ?? []) }
    }

    private func localName(_ element: String) -> String {
        guard let index = element.lastIndex(of: ":") else { return element }
        return String(element[element.index(after: index)...])
    }
}
