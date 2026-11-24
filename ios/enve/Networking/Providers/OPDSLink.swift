import Foundation

struct OPDSLink: Decodable {
    let href: String?
    let type: String?
    /// OPDS 2 allows `rel` to be a string or an array of strings; both forms are preserved as written.
    let rels: [String]
    let title: String?
    let templated: Bool
    let properties: OPDSLinkProperties?
    let width: Int?
    let height: Int?
    /// OPDS 1 carries indirect acquisition as child elements rather than as link properties.
    let inlineIndirectTypes: [String]

    init(
        href: String?,
        type: String? = nil,
        rels: [String] = [],
        title: String? = nil,
        templated: Bool = false,
        properties: OPDSLinkProperties? = nil,
        width: Int? = nil,
        height: Int? = nil,
        inlineIndirectTypes: [String] = []
    ) {
        self.href = href
        self.type = type
        self.rels = rels
        self.title = title
        self.templated = templated
        self.properties = properties
        self.width = width
        self.height = height
        self.inlineIndirectTypes = inlineIndirectTypes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        href = try container.decodeIfPresent(String.self, forKey: .href)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        templated = (try? container.decode(Bool.self, forKey: .templated)) ?? false
        properties = try? container.decode(OPDSLinkProperties.self, forKey: .properties)
        width = try? container.decode(Int.self, forKey: .width)
        height = try? container.decode(Int.self, forKey: .height)
        inlineIndirectTypes = []

        if let many = try? container.decode([String].self, forKey: .rel) {
            rels = many
        } else if let single = try? container.decode(String.self, forKey: .rel) {
            rels = [single]
        } else {
            rels = []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case href, type, rel, title, templated, properties, width, height
    }

    /// Only for choosing between images the feed offers, so a link that states no size never wins.
    var pixelArea: Int? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return width * height
    }

    func hasRel(_ value: String) -> Bool {
        rels.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    func hasAnyRel(_ values: Set<String>) -> Bool {
        rels.contains { values.contains($0.lowercased()) }
    }

    var indirectAcquisitionTypes: [String] {
        (properties?.indirectAcquisition ?? []).flatMap(\.flattenedTypes) + inlineIndirectTypes
    }
}

struct OPDSLinkProperties: Decodable {
    let price: OPDSPrice?
    let indirectAcquisition: [OPDSAcquisitionObject]
    let holds: OPDSHolds?
    let copies: OPDSCopies?
    let availability: OPDSAvailability?
    /// The OPDS Authentication Document a service points at so a client can sign in without a 401 round-trip.
    let authenticate: OPDSAuthenticationHint?
    /// How many publications a navigation entry or facet leads to.
    let numberOfItems: Int?

    init(
        price: OPDSPrice? = nil,
        indirectAcquisition: [OPDSAcquisitionObject] = [],
        holds: OPDSHolds? = nil,
        copies: OPDSCopies? = nil,
        availability: OPDSAvailability? = nil,
        authenticate: OPDSAuthenticationHint? = nil,
        numberOfItems: Int? = nil
    ) {
        self.price = price
        self.indirectAcquisition = indirectAcquisition
        self.holds = holds
        self.copies = copies
        self.availability = availability
        self.authenticate = authenticate
        self.numberOfItems = numberOfItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        price = try? container.decode(OPDSPrice.self, forKey: .price)
        indirectAcquisition = (try? container.decode([OPDSAcquisitionObject].self, forKey: .indirectAcquisition)) ?? []
        holds = try? container.decode(OPDSHolds.self, forKey: .holds)
        copies = try? container.decode(OPDSCopies.self, forKey: .copies)
        availability = try? container.decode(OPDSAvailability.self, forKey: .availability)
        authenticate = try? container.decode(OPDSAuthenticationHint.self, forKey: .authenticate)
        numberOfItems = try? container.decode(Int.self, forKey: .numberOfItems)
    }

    private enum CodingKeys: String, CodingKey {
        case price, indirectAcquisition, holds, copies, availability, authenticate, numberOfItems
    }
}

struct OPDSAuthenticationHint: Decodable {
    let href: String?
    let type: String?

    init(href: String?, type: String? = nil) {
        self.href = href
        self.type = type
    }
}

struct OPDSAcquisitionObject: Decodable {
    let type: String
    let children: [OPDSAcquisitionObject]

    init(type: String, children: [OPDSAcquisitionObject] = []) {
        self.type = type
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        children = (try? container.decode([OPDSAcquisitionObject].self, forKey: .child)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case type, child }

    /// Depth first, so the last entry of a single chain is the file the reader finally receives.
    var flattenedTypes: [String] { [type] + children.flatMap(\.flattenedTypes) }
}

struct OPDSPrice: Decodable {
    let currency: String
    let value: Double

    init(currency: String, value: Double) {
        self.currency = currency
        self.value = value
    }
}

struct OPDSCopies: Decodable {
    let total: Int?
    let available: Int?

    init(total: Int? = nil, available: Int? = nil) {
        self.total = total
        self.available = available
    }
}

struct OPDSHolds: Decodable {
    let total: Int?
    let position: Int?

    init(total: Int? = nil, position: Int? = nil) {
        self.total = total
        self.position = position
    }
}

struct OPDSAvailability: Decodable {
    let state: String
    let detail: String?
    /// OPDS 1.2 loan window, kept verbatim: the feed's own formatting is what the rejection message shows.
    let since: String?
    let until: String?

    init(state: String, detail: String? = nil, since: String? = nil, until: String? = nil) {
        self.state = state
        self.detail = detail
        self.since = since
        self.until = until
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        since = try container.decodeIfPresent(String.self, forKey: .since)
        until = try container.decodeIfPresent(String.self, forKey: .until)
    }

    private enum CodingKeys: String, CodingKey { case state, detail, since, until }

    /// Only an explicit refusal blocks the download; an unfamiliar state must not hide an open publication.
    var allowsImmediateAccess: Bool {
        switch state.lowercased() {
        case "unavailable", "reserved": false
        default: true
        }
    }
}

nonisolated enum OPDSRel {
    static let image: Set<String> = [
        "http://opds-spec.org/image",
        "http://opds-spec.org/image/thumbnail",
        "http://opds-spec.org/cover",
        "http://opds-spec.org/thumbnail",
        "x-stanza-cover-image",
        "x-stanza-cover-image-thumbnail",
        "thumbnail",
    ]

    static let thumbnail: Set<String> = [
        "http://opds-spec.org/image/thumbnail",
        "http://opds-spec.org/thumbnail",
        "x-stanza-cover-image-thumbnail",
        "thumbnail",
    ]

    /// Relations that describe this feed or another view of it. Following them duplicates work or loops.
    private static let structural: Set<String> = [
        "self", "alternate", "related", "search", "up", "start", "via", "current",
        "first", "last", "next", "previous", "prev",
        "http://opds-spec.org/facet",
        "http://opds-spec.org/shelf",
        "http://opds-spec.org/subscriptions",
        "http://opds-spec.org/crawlable",
    ]

    static func isStructural(_ rel: String) -> Bool {
        let value = rel.lowercased()
        return structural.contains(value) || value.hasPrefix("http://opds-spec.org/sort")
    }
}

nonisolated enum OPDSMediaType {
    static func isFeed(_ type: String?) -> Bool {
        guard let type = type?.lowercased() else { return false }
        guard !type.contains("opds-publication+json") else { return false }
        return type.contains("application/opds+json") || type.contains("application/atom+xml")
    }

    static func isWebPage(_ type: String?) -> Bool {
        guard let type = type?.lowercased() else { return false }
        return type.contains("text/html") || type.contains("application/xhtml+xml")
    }
}

nonisolated enum OPDSURL {
    private static let allowedSchemes: Set<String> = ["http", "https"]

    static func resolve(_ href: String, baseURL: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let absolute = URL(string: trimmed)
        let resolved =
            absolute?.scheme == nil
            ? URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
            : absolute
        guard let url = resolved, isRequestable(url) else { return nil }
        return url
    }

    /// Resolve the prefix separately because URL rejects URI-template braces.
    static func resolveTemplate(_ template: String, baseURL: URL) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let split = trimmed.firstIndex(of: "{") ?? trimmed.endIndex
        let prefix = String(trimmed[trimmed.startIndex..<split])
        let suffix = String(trimmed[split...])

        // A template whose first expression opens the query has nothing before it but the feed's own URL.
        guard !prefix.isEmpty else { return baseURL.absoluteString + suffix }
        guard let resolved = resolve(prefix, baseURL: baseURL) else { return nil }
        return resolved.absoluteString + suffix
    }

    static func sameOrigin(_ url: URL, as origin: URL) -> Bool {
        HTTPOrigin(url: origin).matches(url)
    }

    /// All feed URLs must use HTTP(S), have a host, and contain no embedded credentials.
    static func isRequestable(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            allowedSchemes.contains(scheme),
            components.user == nil,
            components.password == nil,
            let host = components.host,
            !host.isEmpty
        else { return false }
        return true
    }
}

nonisolated enum OPDSText {
    static func position(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }

    /// The year of an OPDS publication date, which may be a full timestamp, a date, or a bare year.
    static func year(_ value: String) -> Int? {
        guard let first = value.split(separator: "-").first, first.count == 4 else { return nil }
        return Int(first)
    }
}
