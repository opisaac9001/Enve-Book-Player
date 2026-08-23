import Foundation

struct OpenLibrarySearchResponse: Codable {
    let numFound: Int?
    let docs: [OpenLibraryDoc]?
}

struct OpenLibraryDoc: Codable {
    let key: String?
    let title: String?
    let authorName: [String]?
    let firstPublishYear: Int?
    let isbn: [String]?
    let coverI: Int?
    let publisher: [String]?
    let subject: [String]?
    let language: [String]?
    let numberOfPagesMedian: Int?

    enum CodingKeys: String, CodingKey {
        case key, title, isbn, publisher, subject, language
        case authorName = "author_name"
        case firstPublishYear = "first_publish_year"
        case coverI = "cover_i"
        case numberOfPagesMedian = "number_of_pages_median"
    }
}

struct OpenLibraryMetadataLayer: Codable, Equatable, Sendable {
    var workKey: String?
    var title: String?
    var authors: [String]?
    var publisher: String?
    var publishedYear: Int?
    var isbn: String?
    var coverUrl: String?
    var subjects: [String]?
    var language: String?
    var pageCount: Int?
    var description: String?
    var seriesName: String?
    var seriesNumber: Int?
    var seriesSequence: String?
}

final class OpenLibraryService {
    static let shared = OpenLibraryService()
    private init() {}

    private static let _h = "openlibrary"
    private static let _d = "org"
    private var _base: String { "https://\(Self._h).\(Self._d)" }
    private var _covers: String { "https://covers.\(Self._h).\(Self._d)" }

    private var searchURL: URL { URL(string: "\(_base)/search.json")! }
    private var worksBaseURL: URL { URL(string: _base)! }

    func search(query: String, limit: Int = 20) async throws -> [OpenLibraryDoc] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(min(limit, 100))),
            URLQueryItem(
                name: "fields",
                value: "key,title,author_name,first_publish_year,isbn,cover_i,publisher,subject,language,number_of_pages_median"
            ),
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("enve/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "CatalogService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Search failed (\(http.statusCode))"]
            )
        }
        let decoded = try JSONDecoder().decode(OpenLibrarySearchResponse.self, from: data)
        return decoded.docs ?? []
    }

    func getWorkDescription(workKey: String) async throws -> String? {
        let normalized = workKey.hasPrefix("/") ? String(workKey.dropFirst()) : workKey
        let url = worksBaseURL.appending(path: "\(normalized).json")
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("enve/1.0", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let desc = json["description"] as? String {
                return desc
            } else if let descObj = json["description"] as? [String: Any], let value = descObj["value"] as? String {
                return value
            }
        }
        return nil
    }

    func coverURL(coverId: Int, size: String = "L") -> String {
        return "\(_covers)/b/id/\(coverId)-\(size).jpg"
    }

    func toMetadataLayer(_ doc: OpenLibraryDoc) -> OpenLibraryMetadataLayer {
        let cover: String? = doc.coverI.map { coverURL(coverId: $0, size: "L") }
        let series = seriesInfo(title: doc.title, subjects: doc.subject)
        return OpenLibraryMetadataLayer(
            workKey: doc.key,
            title: doc.title,
            authors: doc.authorName,
            publisher: doc.publisher?.first,
            publishedYear: doc.firstPublishYear,
            isbn: doc.isbn?.first,
            coverUrl: cover,
            subjects: doc.subject,
            language: doc.language?.first,
            pageCount: doc.numberOfPagesMedian,
            description: nil,
            seriesName: series.name,
            seriesNumber: series.number,
            seriesSequence: series.sequence
        )
    }

    func seriesInfo(title: String?, subjects: [String]?) -> (name: String?, number: Int?, sequence: String?) {
        let subjectInfo = subjects?
            .lazy
            .compactMap { self.seriesInfo(fromSubject: $0) }
            .first
        let number = subjectInfo?.number ?? extractSeriesNumber(from: title)
        return (subjectInfo?.name, number, number.map(String.init))
    }

    private func seriesInfo(fromSubject subject: String) -> (name: String?, number: Int?)? {
        guard subject.lowercased().hasPrefix("series:") else { return nil }
        let raw = String(subject.dropFirst("series:".count))
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let number = extractSeriesNumber(from: raw)
        let name =
            raw
            .replacingOccurrences(of: #"(?i)\s*(?:#|book|volume|vol\.?)\s*\d+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? raw : name, number)
    }

    private func extractSeriesNumber(from text: String?) -> Int? {
        guard let text else { return nil }
        let patterns = [
            #"(?i)(?:book|volume|vol\.?)\s*(\d+)"#,
            #"(?i)#\s*(\d+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                match.numberOfRanges > 1,
                let capture = Range(match.range(at: 1), in: text),
                let number = Int(text[capture])
            else { continue }
            return number
        }
        return nil
    }
}
