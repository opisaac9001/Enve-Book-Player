import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

class AudibleService {
    static let shared = AudibleService()

    private let baseURL = URL(string: "https://api.audible.com/1.0/catalog/products")!

    private func looksLikeASIN(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard s.count == 10 else { return false }
        return s.allSatisfy { $0.isNumber || ($0 >= "A" && $0 <= "Z") }
    }

    private struct AudibleAPIResponse: Codable {
        let products: [AudibleProduct]
    }

    private struct AudibleProductDetailResponse: Codable {
        let product: AudibleProduct
    }

    private struct AudibleProduct: Codable {
        let asin: String
        let title: String
        let subtitle: String?
        let authors: [AudibleContributor]?
        let narrators: [AudibleContributor]?
        let runtimeLengthMin: Int?
        let releaseDate: String?
        let publicationDate: String?
        let productImages: [String: String]?
        let publisherName: String?
        let series: [AudibleSeries]?
        let genres: [AudibleGenre]?
        let categoryLadders: [AudibleCategoryLadder]?
        let rating: AudibleRating?
        let formatType: String?
        let htmlDescription: String?
        let summary: String?
        let publisherSummary: String?
        let productDescription: String?
        let editorialReview: String?
        let shortSummary: String?
    }

    private struct AudibleContributor: Codable {
        let name: String
    }

    private struct AudibleSeries: Codable {
        let title: String
        let sequence: String?
    }

    private struct AudibleGenre: Codable {
        let name: String
    }

    private struct AudibleCategoryLadder: Codable {
        let root: [AudibleCategory]?
        let ladder: [AudibleCategory]?

        enum CodingKeys: String, CodingKey {
            case root, ladder
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            var categories: [AudibleCategory]? = nil

            if container.contains(.ladder) {
                if let ladderArray = try? container.decode([AudibleCategory].self, forKey: .ladder) {
                    categories = ladderArray
                }
            }

            if categories == nil && container.contains(.root) {
                if let rootArray = try? container.decode([AudibleCategory].self, forKey: .root) {
                    categories = rootArray
                } else if (try? container.decode(String.self, forKey: .root)) != nil {
                }
            }

            self.ladder = categories
            self.root = categories
        }
    }

    private struct AudibleCategory: Codable {
        let name: String?
        let type: String?
    }

    private struct AudibleRating: Codable {
        let overallDistribution: AudibleRatingDistribution?
        let numReviews: Int?
    }

    private struct AudibleRatingDistribution: Codable {
        let averageRating: Double?
        let displayAverageRating: String?
    }

    private func cleanSearchQuery(_ query: String) -> String {
        var cleaned = query

        cleaned = cleaned.replacingOccurrences(of: ":", with: " ")

        cleaned = cleaned.replacingOccurrences(of: "-", with: " ")

        cleaned = cleaned.replacingOccurrences(
            of: "\\([^)]*\\)",
            with: "",
            options: .regularExpression
        )

        cleaned = cleaned.replacingOccurrences(
            of: "\\[[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )

        cleaned = cleaned.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func encodeForURL(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func simpleSearch(
        query: String,
        numResults: Int = 50,
        countryCode: String? = nil
    ) async throws -> [AudibleSearchResult] {
        let cleanedQuery = cleanSearchQuery(query)

        guard !cleanedQuery.isEmpty else {
            AppLogger.network.info("Search query is empty after cleaning")
            return []
        }

        AppLogger.network.info("search: '\(cleanedQuery)'")

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(
                name: "response_groups",
                value: "contributors,product_attrs,product_desc,media,product_extended_attrs,series,category_ladders"
            ),
            URLQueryItem(name: "num_results", value: String(min(50, max(1, numResults)))),
            URLQueryItem(name: "products_sort_by", value: "Relevance"),
            URLQueryItem(name: "image_sizes", value: "500,1024"),
            URLQueryItem(name: "keywords", value: cleanedQuery),
        ]

        if let cc = countryCode, !cc.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "country_code", value: cc))
        }

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        AppLogger.network.info("searching…")

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, urlResponse) = try await URLSession.shared.data(for: request)

        if let http = urlResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? "<non-utf8>"
            throw NSError(
                domain: "AudibleService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Metadata search failed (\(http.statusCode)). \(snippet)"]
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let decoded = try decoder.decode(AudibleAPIResponse.self, from: data)

        AppLogger.network.debug("returned \(decoded.products.count) results")

        for (i, product) in decoded.products.prefix(3).enumerated() {
            AppLogger.network.debug(
                "[\(i)] resultId=\(DiagnosticLogSanitizer.identifier(for: product.title))"
            )
        }

        return decoded.products.map { product in
            var coverUrl: String?
            if let images = product.productImages {
                coverUrl = images["500"] ?? images["1024"] ?? images.values.first
            }

            return AudibleSearchResult(
                asin: product.asin,
                title: product.title,
                authors: product.authors?.map { $0.name } ?? [],
                narrators: product.narrators?.map { $0.name } ?? [],
                duration: (product.runtimeLengthMin ?? 0) * 60,
                releaseDate: product.releaseDate,
                coverUrl: coverUrl,
                rating: product.rating?.overallDistribution?.averageRating,
                description: product.htmlDescription ?? product.summary
            )
        }
    }

    func simpleSearchPaged(
        query: String,
        numResultsPerPage: Int = 50,
        maxPages: Int = 3,
        countryCode: String? = nil
    ) async throws -> [AudibleSearchResult] {
        let cleanedQuery = cleanSearchQuery(query)

        guard !cleanedQuery.isEmpty else {
            AppLogger.network.info("Paged search: query is empty after cleaning")
            return []
        }

        AppLogger.network.info("paged search starting")
        AppLogger.network.info("query: '\(cleanedQuery)'")
        AppLogger.network.info("region: \(countryCode ?? "default")")

        var allResults: [AudibleSearchResult] = []
        let perPage = min(50, max(1, numResultsPerPage))

        for page in 0..<maxPages {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)!

            var queryItems = [
                URLQueryItem(
                    name: "response_groups",
                    value: "contributors,product_attrs,product_desc,media,product_extended_attrs,series,category_ladders"
                ),
                URLQueryItem(name: "num_results", value: String(perPage)),
                URLQueryItem(name: "products_sort_by", value: "Relevance"),
                URLQueryItem(name: "image_sizes", value: "500,1024"),
                URLQueryItem(name: "keywords", value: cleanedQuery),
            ]

            if page > 0 {
                queryItems.append(URLQueryItem(name: "page", value: String(page)))
            }

            components.queryItems = queryItems

            if let cc = countryCode, !cc.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "country_code", value: cc))
            }

            guard var urlString = components.url?.absoluteString else {
                AppLogger.network.error("Failed to create URL from components")
                continue
            }

            urlString = urlString.replacingOccurrences(of: "+", with: "%20")

            guard let url = URL(string: urlString) else {
                AppLogger.network.error("Failed to create URL from: \(urlString)")
                continue
            }

            if page == 1 {
                AppLogger.network.info("paged search running…")
            }

            let (data, urlResponse) = try await URLSession.shared.data(from: url)

            if let http = urlResponse as? HTTPURLResponse {
                if !(200...299).contains(http.statusCode) {
                    AppLogger.network.error("error: \(http.statusCode)")
                    break
                }
            }

            if page == 1 {
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            do {
                let decoded = try decoder.decode(AudibleAPIResponse.self, from: data)

                if page == 1 {
                    AppLogger.network.info("page 1: \(decoded.products.count) results")
                }

                if decoded.products.isEmpty {
                    AppLogger.network.info("page \(page) empty, stopping")
                    break
                }

                let pageResults = decoded.products.map { product -> AudibleSearchResult in
                    var coverUrl: String?
                    if let images = product.productImages {
                        coverUrl = images["500"] ?? images["1024"] ?? images.values.first
                    }

                    return AudibleSearchResult(
                        asin: product.asin,
                        title: product.title,
                        authors: product.authors?.map { $0.name } ?? [],
                        narrators: product.narrators?.map { $0.name } ?? [],
                        duration: (product.runtimeLengthMin ?? 0) * 60,
                        releaseDate: product.releaseDate,
                        coverUrl: coverUrl,
                        rating: product.rating?.overallDistribution?.averageRating,
                        description: product.htmlDescription ?? product.summary
                    )
                }

                allResults.append(contentsOf: pageResults)

                if pageResults.count < perPage {
                    break
                }
            } catch {
                AppLogger.network.error("decode error on page \(page)")
                break
            }
        }

        AppLogger.network.info("paged search complete: \(allResults.count) total results")

        var seen = Set<String>()
        return allResults.filter { seen.insert($0.asin).inserted }
    }

    enum SearchField {
        case title
        case keywords
    }

    func search(
        query: String,
        numResults: Int = 10,
        page: Int = 0,
        field: SearchField = .title,
        author: String? = nil,
        countryCode: String? = nil
    ) async throws -> [AudibleSearchResult] {
        let searchQuery = cleanSearchQuery(query)

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)!

        var queryItems: [URLQueryItem] = [
            URLQueryItem(
                name: "response_groups",
                value: "contributors,product_attrs,product_desc,media,product_extended_attrs,series,category_ladders"
            ),
            URLQueryItem(name: "num_results", value: String(min(50, max(1, numResults)))),
            URLQueryItem(name: "products_sort_by", value: "Relevance"),
            URLQueryItem(name: "image_sizes", value: "500,1024"),
        ]

        if page > 0 {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }

        switch field {
        case .title:
            queryItems.append(URLQueryItem(name: "title", value: searchQuery))
        case .keywords:
            queryItems.append(URLQueryItem(name: "keywords", value: searchQuery))
        }

        if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "author", value: cleanSearchQuery(author)))
        }

        if let cc = countryCode, !cc.isEmpty {
            queryItems.append(URLQueryItem(name: "country_code", value: cc))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        AppLogger.network.info("title search…")

        let (data, urlResponse) = try await URLSession.shared.data(from: url)

        if let http = urlResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? "<non-utf8>"
            throw NSError(
                domain: "AudibleService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Metadata search failed (\(http.statusCode)). \(snippet)"]
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let decoded = try decoder.decode(AudibleAPIResponse.self, from: data)

        AppLogger.network.info("title results: \(decoded.products.count)")

        return decoded.products.map { product in
            var coverUrl: String?
            if let images = product.productImages {
                coverUrl = images["500"] ?? images["1024"] ?? images.values.first
            }

            return AudibleSearchResult(
                asin: product.asin,
                title: product.title,
                authors: product.authors?.map { $0.name } ?? [],
                narrators: product.narrators?.map { $0.name } ?? [],
                duration: (product.runtimeLengthMin ?? 0) * 60,
                releaseDate: product.releaseDate,
                coverUrl: coverUrl,
                rating: product.rating?.overallDistribution?.averageRating,
                description: product.htmlDescription ?? product.summary,
                seriesName: product.series?.first?.title,
                seriesPosition: product.series?.first?.sequence
            )
        }
    }

    func searchAll(
        query: String,
        numResultsPerPage: Int = 50,
        maxPages: Int = 5,
        field: SearchField = .title,
        author: String? = nil,
        countryCode: String? = nil
    ) async throws -> [AudibleSearchResult] {
        let perPage = max(1, min(50, numResultsPerPage))
        let pages = max(1, maxPages)

        var all: [AudibleSearchResult] = []

        for page in 0..<pages {
            let results = try await search(
                query: query,
                numResults: perPage,
                page: page,
                field: field,
                author: author,
                countryCode: countryCode
            )
            if results.isEmpty { break }
            all.append(contentsOf: results)
            if results.count < perPage { break }
        }

        var seen = Set<String>()
        return all.filter { seen.insert($0.asin).inserted }
    }

    func searchAllBestEffort(
        query: String,
        author: String? = nil,
        countryCode: String? = nil,
        numResultsPerPage: Int = 50,
        maxPages: Int = 5
    ) async throws -> [AudibleSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if looksLikeASIN(trimmedQuery) {
            if let hit = try? await getSearchResultByASIN(asin: trimmedQuery, countryCode: countryCode) {
                return [hit]
            }
        }

        return try await simpleSearchPaged(
            query: trimmedQuery,
            numResultsPerPage: numResultsPerPage,
            maxPages: maxPages,
            countryCode: countryCode
        )
    }

    func getSearchResultByASIN(asin: String, countryCode: String? = nil) async throws -> AudibleSearchResult {
        let url = baseURL.appendingPathComponent(asin)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_groups", value: "contributors,product_attrs,media,product_desc,series,reviews,category_ladders"),
            URLQueryItem(name: "image_sizes", value: "500,1024"),
        ]
        if let cc = countryCode, !cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "country_code", value: cc))
        }
        components.queryItems = items
        guard let requestUrl = components.url else { throw URLError(.badURL) }

        AppLogger.network.info("identifier lookup…")

        let (data, urlResponse) = try await URLSession.shared.data(from: requestUrl)
        if let http = urlResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? "<non-utf8>"
            throw NSError(
                domain: "AudibleService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "ASIN lookup failed (\(http.statusCode)). \(snippet)"]
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(AudibleProductDetailResponse.self, from: data)
        let p = response.product

        var coverUrl: String?
        if let images = p.productImages {
            coverUrl = images["500"] ?? images["1024"] ?? images.values.first
        }

        return AudibleSearchResult(
            asin: p.asin,
            title: p.title,
            authors: p.authors?.map { $0.name } ?? [],
            narrators: p.narrators?.map { $0.name } ?? [],
            duration: (p.runtimeLengthMin ?? 0) * 60,
            releaseDate: p.releaseDate,
            coverUrl: coverUrl,
            rating: p.rating?.overallDistribution?.averageRating,
            description: p.htmlDescription ?? p.summary,
            seriesName: p.series?.first?.title,
            seriesPosition: p.series?.first?.sequence
        )
    }

    func getProductDetails(asin: String, countryCode: String? = nil) async throws -> AudibleMetadataLayer {
        let url = baseURL.appendingPathComponent(asin)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!

        var queryItems: [URLQueryItem] = [
            URLQueryItem(
                name: "response_groups",
                value: "contributors,product_attrs,product_desc,media,product_extended_attrs,series,reviews,category_ladders"
            ),
            URLQueryItem(name: "image_sizes", value: "500,1024"),
        ]

        if let cc = countryCode, !cc.isEmpty {
            queryItems.append(URLQueryItem(name: "country_code", value: cc))
        }

        components.queryItems = queryItems

        guard let requestUrl = components.url else { throw URLError(.badURL) }

        AppLogger.network.info("fetching details for: \(asin)")

        let (data, urlResponse) = try await URLSession.shared.data(from: requestUrl)

        if let http = urlResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? "<non-utf8>"
            throw NSError(
                domain: "AudibleService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Product details failed (\(http.statusCode)). \(snippet)"]
            )
        }

        var rawTagsFromJSON: [String] = []
        var seenTagsFromJSON = Set<String>()

        func extractCategoriesFromJSON(from categoryDict: [String: Any], into tags: inout [String], seen: inout Set<String>, depth: Int = 0)
        {
            if let name = categoryDict["name"] as? String {
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedName.isEmpty {
                    let lowerName = trimmedName.lowercased()
                    if seen.insert(lowerName).inserted {
                        tags.append(trimmedName)
                    }
                }
            }

            if let children = categoryDict["children"] as? [[String: Any]] {
                for child in children {
                    extractCategoriesFromJSON(from: child, into: &tags, seen: &seen, depth: depth + 1)
                }
            } else if let children = categoryDict["children"] as? [Any] {
                for child in children {
                    if let childDict = child as? [String: Any] {
                        extractCategoriesFromJSON(from: childDict, into: &tags, seen: &seen, depth: depth + 1)
                    }
                }
            }

            for (key, value) in categoryDict {
                if key == "name" || key == "id" || key == "children" { continue }
                if let nestedArray = value as? [[String: Any]] {
                    for item in nestedArray {
                        extractCategoriesFromJSON(from: item, into: &tags, seen: &seen, depth: depth + 1)
                    }
                } else if let nestedArray = value as? [Any] {
                    for item in nestedArray {
                        if let itemDict = item as? [String: Any] {
                            extractCategoriesFromJSON(from: itemDict, into: &tags, seen: &seen, depth: depth + 1)
                        }
                    }
                }
            }
        }

        if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let product = jsonObject["product"] as? [String: Any]
        {

            if let thesaurusKeywords = product["thesaurus_subject_keywords"] {
                if let keywordsArray = thesaurusKeywords as? [String] {
                    for keyword in keywordsArray {
                        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            let lower = trimmed.lowercased()
                            if seenTagsFromJSON.insert(lower).inserted {
                                rawTagsFromJSON.append(trimmed)
                            }
                        }
                    }
                } else if let keywordsArray = thesaurusKeywords as? [Any] {
                    for item in keywordsArray {
                        if let keyword = item as? String {
                            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                let lower = trimmed.lowercased()
                                if seenTagsFromJSON.insert(lower).inserted {
                                    rawTagsFromJSON.append(trimmed)
                                }
                            }
                        }
                    }
                }
            }

            if let categoryLadders = product["category_ladders"] as? [[String: Any]] {
                for ladder in categoryLadders {
                    if let ladderArray = ladder["ladder"] as? [[String: Any]] {
                        for category in ladderArray {
                            extractCategoriesFromJSON(from: category, into: &rawTagsFromJSON, seen: &seenTagsFromJSON, depth: 0)
                        }
                    }
                    if let rootArray = ladder["root"] as? [[String: Any]] {
                        for category in rootArray {
                            extractCategoriesFromJSON(from: category, into: &rawTagsFromJSON, seen: &seenTagsFromJSON, depth: 0)
                        }
                    }
                    for (key, value) in ladder {
                        if key == "root" || key == "ladder" { continue }
                        if let nestedArray = value as? [[String: Any]] {
                            for item in nestedArray {
                                extractCategoriesFromJSON(from: item, into: &rawTagsFromJSON, seen: &seenTagsFromJSON, depth: 0)
                            }
                        }
                    }
                }
            }
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(AudibleProductDetailResponse.self, from: data)
        let p = response.product

        var seriesName: String?
        var seriesNum: String?
        if let firstSeries = p.series?.first {
            seriesName = firstSeries.title
            seriesNum = firstSeries.sequence
        }

        var coverUrl: String?
        if let images = p.productImages {
            coverUrl = images["500"] ?? images["1024"] ?? images.values.first
        }

        if coverUrl != nil {
            AppLogger.network.info("cover found")
        }

        let descriptionCandidate =
            p.htmlDescription
            ?? p.publisherSummary
            ?? p.summary
            ?? p.productDescription
            ?? p.editorialReview
            ?? p.shortSummary

        let htmlDescription = descriptionCandidate
        let plainDescription: String?
        if let html = htmlDescription, let data = html.data(using: .utf8) {
            if let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
            ) {
                let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
                plainDescription = text.isEmpty ? nil : text
            } else {
                let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                plainDescription = stripped.isEmpty ? nil : stripped
            }
        } else {
            plainDescription = nil
        }

        var rawTags = rawTagsFromJSON

        if let genres = p.genres {
            for genre in genres {
                let genreName = genre.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !genreName.isEmpty {
                    let lowerName = genreName.lowercased()
                    if !rawTags.contains(where: { $0.lowercased() == lowerName }) {
                        rawTags.append(genreName)
                    }
                }
            }
        }

        let filteredTags = AudibleTagFilter.filter(rawTags, droppingFirst: false)
        AppLogger.network.info("\(filteredTags.count) tags extracted")

        return AudibleMetadataLayer(
            asin: p.asin,
            title: p.title,
            subtitle: p.subtitle,
            author: p.authors?.map({ $0.name }).joined(separator: ", "),
            narrators: p.narrators?.map { $0.name },
            series: seriesName,
            seriesNumber: seriesNum,
            description: htmlDescription,
            descriptionPlain: plainDescription,
            coverUrl: coverUrl,
            publisher: p.publisherName,
            publishedYear: Int(p.releaseDate?.prefix(4) ?? "") ?? Int(p.publicationDate?.prefix(4) ?? ""),
            releaseDate: p.releaseDate,
            genres: p.genres?.map { $0.name },
            tags: filteredTags.isEmpty ? nil : filteredTags,
            rating: p.rating?.overallDistribution?.averageRating,
            ratingCount: p.rating?.numReviews,
            duration: TimeInterval((p.runtimeLengthMin ?? 0) * 60),
            language: nil,
            format: p.formatType
        )
    }
}
