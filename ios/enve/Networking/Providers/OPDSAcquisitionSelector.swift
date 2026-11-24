import Foundation

enum OPDSAcquisitionKind {
    case openAccess
    case direct
    case preview
    case borrow
    case buy
    case subscribe

    /// OPDS 2.0 allows the short form of every acquisition relation alongside the OPDS 1 URI form.
    init?(rel: String) {
        switch rel.lowercased() {
        case "http://opds-spec.org/acquisition/open-access", "open-access":
            self = .openAccess
        case "http://opds-spec.org/acquisition", "acquisition":
            self = .direct
        case "http://opds-spec.org/acquisition/sample", "sample", "preview":
            self = .preview
        case "http://opds-spec.org/acquisition/borrow", "borrow":
            self = .borrow
        case "http://opds-spec.org/acquisition/buy", "buy":
            self = .buy
        case "http://opds-spec.org/acquisition/subscribe", "subscribe":
            self = .subscribe
        default:
            return nil
        }
    }

    /// Only these two hand back the file itself; the rest need a transaction Enve does not perform.
    var deliversTheFile: Bool { self == .openAccess || self == .direct }

    /// An acquisition the reader completes on the catalog's own site.
    var isTransaction: Bool { self == .borrow || self == .buy || self == .subscribe }

    /// Lower is more permissive. Both selection and the rejection message depend on this order.
    var preferenceRank: Int {
        switch self {
        case .openAccess: 0
        case .direct: 1
        case .preview: 2
        case .borrow: 3
        case .buy: 4
        case .subscribe: 5
        }
    }

    var actionName: String {
        switch self {
        case .openAccess, .direct: "Download"
        case .preview: "Download sample"
        case .borrow: "Borrow"
        case .buy: "Buy"
        case .subscribe: "Subscribe"
        }
    }
}

struct OPDSAcquisition {
    let url: URL
    let kind: OPDSAcquisitionKind
    let format: OPDSPublicationFormat
    let properties: OPDSLinkProperties?
    let title: String?

    init(
        url: URL,
        kind: OPDSAcquisitionKind,
        format: OPDSPublicationFormat,
        properties: OPDSLinkProperties? = nil,
        title: String? = nil
    ) {
        self.url = url
        self.kind = kind
        self.format = format
        self.properties = properties
        self.title = title
    }

    var price: OPDSPrice? { properties?.price }
    var availability: OPDSAvailability? { properties?.availability }
    var copies: OPDSCopies? { properties?.copies }
    var holds: OPDSHolds? { properties?.holds }
}

enum OPDSAcquisitionSelection {
    case downloadable(OPDSAcquisition)
    case rejected(reason: String)
    /// No acquisition link at all: in an Atom feed this is how a navigation entry looks.
    case notAPublication(reason: String)
}

enum OPDSAcquisitionSelector {
    static func select(links: [OPDSLink], baseURL: URL) -> OPDSAcquisitionSelection {
        selection(among: candidates(in: links, baseURL: baseURL))
    }

    static func selection(among ordered: [OPDSAcquisition]) -> OPDSAcquisitionSelection {
        guard let best = ordered.first else {
            return .notAPublication(reason: "The entry offers no acquisition link.")
        }
        if let usable = ordered.first(where: isDownloadable) {
            return .downloadable(usable)
        }
        return .rejected(reason: reason(for: best))
    }

    /// Ordered most to least preferred so selection and the rejection message are deterministic.
    static func candidates(in links: [OPDSLink], baseURL: URL) -> [OPDSAcquisition] {
        var ranked: [(rank: (Int, Int, Int), acquisition: OPDSAcquisition)] = []
        for (index, link) in links.enumerated() {
            guard !link.templated,
                let href = link.href,
                let url = OPDSURL.resolve(href, baseURL: baseURL),
                !link.hasAnyRel(OPDSRel.image)
            else { continue }

            let format = OPDSPublicationFormat.resolve(link: link, url: url)
            guard let kind = kind(for: link, format: format) else { continue }
            ranked.append(
                (
                    (kind.preferenceRank, format.preferenceRank, index),
                    OPDSAcquisition(
                        url: url,
                        kind: kind,
                        format: format,
                        properties: link.properties,
                        title: link.title
                    )
                )
            )
        }
        return ranked.sorted { $0.rank < $1.rank }.map(\.acquisition)
    }

    static func isDownloadable(_ acquisition: OPDSAcquisition) -> Bool {
        acquisition.kind.deliversTheFile
            && acquisition.format.isSupported
            && acquisition.properties?.availability?.allowsImmediateAccess != false
    }

    /// Loose audio acquisitions cannot be imported without a library publication to own playback.
    static func undeliverableReason(for acquisition: OPDSAcquisition) -> String? {
        switch acquisition.format {
        case .ebook: nil
        case .audio: "Enve plays an audio publication from the library, not from a catalogue link."
        case .protected(let scheme): "\(scheme) protected content is not supported."
        case .unsupported(let name): "\(name) is not a format Enve can open."
        case .unrecognized: "The acquisition link does not advertise a readable publication format."
        }
    }

    static func reason(for acquisition: OPDSAcquisition) -> String {
        switch acquisition.format {
        case .protected(let scheme):
            return "\(scheme) protected content is not supported."
        case .unsupported(let name):
            return "\(name) is not a format Enve can open."
        case .unrecognized:
            return "The acquisition link does not advertise a readable publication format."
        case .ebook, .audio:
            break
        }

        switch acquisition.kind {
        case .preview:
            return "Only a preview is offered for this publication."
        case .buy:
            return "Only offered for purchase\(priceText(acquisition.properties?.price))."
        case .borrow:
            return "Only offered to borrow\(loanText(acquisition.properties))."
        case .subscribe:
            return "Only offered through a subscription."
        case .openAccess, .direct:
            return "The server reports this publication as \(availabilityText(acquisition.properties))."
        }
    }

    /// A one-line summary of an acquisition's terms, for the row that offers it.
    static func termsText(for acquisition: OPDSAcquisition) -> String? {
        var parts: [String] = []
        if let price = acquisition.price {
            parts.append("\(String(format: "%.2f", price.value)) \(price.currency)")
        }
        parts.append(contentsOf: copiesText(acquisition.properties))
        if let availability = acquisition.availability, !availability.allowsImmediateAccess {
            // The state alone: the loan window follows it, and `availabilityText` would repeat it here.
            var state = availability.state
            if let detail = availability.detail, !detail.isEmpty { state += " — \(detail)" }
            parts.append(state)
        }
        parts.append(contentsOf: loanWindow(acquisition.availability))
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func kind(for link: OPDSLink, format: OPDSPublicationFormat) -> OPDSAcquisitionKind? {
        let declared = link.rels.compactMap(OPDSAcquisitionKind.init(rel:))
        if let mostRestrictive = declared.max(by: { $0.preferenceRank < $1.preferenceRank }) {
            return mostRestrictive
        }
        // Some catalogs omit the acquisition relation and rely on the media type alone.
        guard format.isPublication, !link.rels.contains(where: OPDSRel.isStructural) else { return nil }
        return .direct
    }

    private static func priceText(_ price: OPDSPrice?) -> String {
        guard let price else { return "" }
        return " for \(String(format: "%.2f", price.value)) \(price.currency)"
    }

    private static func copiesText(_ properties: OPDSLinkProperties?) -> [String] {
        var parts: [String] = []
        // Zero is meaningful here: every copy is out, which is not the same as the server omitting the field.
        switch (properties?.copies?.available, properties?.copies?.total) {
        case let (available?, total?): parts.append("\(available) of \(total) copies available")
        case let (available?, nil): parts.append("\(available) copies available")
        case let (nil, total?): parts.append("\(total) copies")
        case (nil, nil): break
        }
        if let total = properties?.holds?.total { parts.append("\(total) holds") }
        if let position = properties?.holds?.position { parts.append("position \(position) in the queue") }
        return parts
    }

    private static func loanText(_ properties: OPDSLinkProperties?) -> String {
        var parts = copiesText(properties)
        parts.append(contentsOf: loanWindow(properties?.availability))
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    private static func availabilityText(_ properties: OPDSLinkProperties?) -> String {
        guard let availability = properties?.availability else { return "unavailable" }
        var text = availability.state
        if let detail = availability.detail, !detail.isEmpty { text += " — \(detail)" }
        let window = loanWindow(availability)
        return window.isEmpty ? text : "\(text) (\(window.joined(separator: ", ")))"
    }

    private static func loanWindow(_ availability: OPDSAvailability?) -> [String] {
        var parts: [String] = []
        if let since = availability?.since, !since.isEmpty { parts.append("since \(since)") }
        if let until = availability?.until, !until.isEmpty { parts.append("until \(until)") }
        return parts
    }
}

enum OPDSPublicationFormat: Equatable {
    case ebook(EbookFormat)
    case audio
    /// Recognized publication packaging that Enve has no reader for.
    case unsupported(String)
    case protected(String)
    case unrecognized

    static func resolve(link: OPDSLink, url: URL) -> OPDSPublicationFormat {
        var chain: [String] = []
        if let type = link.type { chain.append(type) }
        chain.append(contentsOf: link.indirectAcquisitionTypes)

        if let scheme = chain.compactMap(drmScheme(for:)).first { return .protected(scheme) }
        // The deepest node of an indirect acquisition chain is the file actually delivered.
        if let format = chain.reversed().compactMap(supportedEbookFormat(for:)).first { return .ebook(format) }
        if chain.contains(where: isAudio) { return .audio }
        if let name = chain.compactMap(unsupportedPackaging(for:)).first { return .unsupported(name) }

        guard chain.isEmpty || chain.contains(where: isOpaqueBinary) else { return .unrecognized }
        return resolveFromPath(url)
    }

    static func drmScheme(for mime: String) -> String? {
        switch normalized(mime) {
        case "application/vnd.readium.lcp.license.v1.0+json",
            "application/vnd.readium.lcp.license-1.0+json",
            "application/epub+lcp",
            "application/audiobook+lcp",
            "application/divina+lcp",
            "application/pdf+lcp":
            return "Readium LCP"
        case "application/vnd.adobe.adept+xml", "application/vnd.adobe.drm+xml":
            return "Adobe DRM"
        case "audio/vnd.audible.aax", "audio/vnd.audible.aaxc", "audio/x-pn-audibleaudio":
            return "Audible DRM"
        default:
            return nil
        }
    }

    var isPublication: Bool { self != .unrecognized }

    var isSupported: Bool {
        switch self {
        case .ebook, .audio: true
        case .unsupported, .protected, .unrecognized: false
        }
    }

    var mediaType: AppMediaType {
        switch self {
        case .audio: .audiobook
        case .ebook, .unsupported, .protected, .unrecognized: .ebook
        }
    }

    var ebookFormat: EbookFormat? {
        guard case .ebook(let format) = self else { return nil }
        return format
    }

    /// Preference between several usable acquisitions for the same publication.
    var preferenceRank: Int {
        switch self {
        case .ebook(let format): Self.rank(of: format)
        case .audio: 9
        case .unsupported: 10
        case .protected: 11
        case .unrecognized: 12
        }
    }

    private static func rank(of format: EbookFormat) -> Int {
        switch format {
        case .epub: 0
        case .pdf: 1
        case .cbz: 2
        case .cbr: 3
        case .fb2: 4
        case .azw3: 5
        case .azw: 6
        case .mobi: 7
        case .imagefolder: 8
        }
    }

    /// Directly playable audio formats; DRM-protected Audible aax/aa are rejected.
    private static let audioMIMETypesByExtension: [String: String] = [
        "mp3": "audio/mpeg",
        "m4a": "audio/mp4",
        "m4b": "audio/mp4",
        "aac": "audio/aac",
        "flac": "audio/flac",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "oga": "audio/ogg",
        "opus": "audio/opus",
    ]

    static func audioMIMEType(forPathOf url: URL) -> String? {
        audioMIMETypesByExtension[url.pathExtension.lowercased()]
    }

    private static func normalized(_ mime: String) -> String {
        mime.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    private static func supportedEbookFormat(for mime: String) -> EbookFormat? {
        switch normalized(mime) {
        case "application/epub+zip", "application/epub": .epub
        case "application/pdf": .pdf
        case "application/vnd.comicbook+zip", "application/x-cbz", "application/comicbook+zip": .cbz
        case "application/vnd.comicbook-rar", "application/x-cbr", "application/comicbook-rar",
            "application/vnd.rar", "application/x-rar-compressed":
            .cbr
        case "application/x-mobipocket-ebook": .mobi
        case "application/x-mobi8-ebook", "application/vnd.amazon.ebook": .azw3
        case "application/x-fictionbook+xml", "application/fb2+xml", "text/fb2+xml": .fb2
        default: nil
        }
    }

    private static func isAudio(_ mime: String) -> Bool {
        normalized(mime).hasPrefix("audio/")
    }

    private static func unsupportedPackaging(for mime: String) -> String? {
        switch normalized(mime) {
        case "application/audiobook+zip": "A Readium audiobook package"
        case "application/audiobook+json": "A Readium audiobook manifest"
        case "application/webpub+zip": "A Readium Web Publication package"
        case "application/webpub+json": "A Readium Web Publication manifest"
        case "application/divina+zip": "A DiViNa package"
        case "application/divina+json": "A DiViNa manifest"
        default: nil
        }
    }

    /// Unlike a known book download, a bare archive MIME type does not identify a publication.
    private static func isOpaqueBinary(_ mime: String) -> Bool {
        ["application/octet-stream", "binary/octet-stream", "application/zip", "application/x-zip-compressed"]
            .contains(normalized(mime))
    }

    private static func resolveFromPath(_ url: URL) -> OPDSPublicationFormat {
        let ext = url.pathExtension.lowercased()
        if let format = EbookFormat.from(fileExtension: ext), format != .imagefolder { return .ebook(format) }
        if ext == "aax" || ext == "aa" { return .protected("Audible DRM") }
        if audioMIMETypesByExtension[ext] != nil { return .audio }
        return .unrecognized
    }
}
