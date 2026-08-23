import Combine
import Foundation
import Logging
import UniformTypeIdentifiers

extension BookSourceProvider {
    func buildURL(base: String, path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: base) else {
            throw URLError(.badURL)
        }

        components.path = path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        return url
    }

    func addAuthHeaders(to request: inout URLRequest, token: String?, headerName: String = "Authorization") {
        if let token = token {
            request.setValue(token, forHTTPHeaderField: headerName)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }
}

extension RemoteItem {
    static func fromFileURL(_ url: URL, parentId: String? = nil) -> RemoteItem {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        let modifiedDate = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        return RemoteItem(
            id: url.path,
            name: url.lastPathComponent,
            isFolder: isDirectory.boolValue,
            size: size,
            mimeType: url.mimeType,
            modifiedDate: modifiedDate,
            pathHint: url.path,
            parentId: parentId
        )
    }

    var formattedSize: String? {
        guard let size = size else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

extension URL {
    var mimeType: String? {
        if let typeIdentifier = try? resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier {
            if let utType = UTType(typeIdentifier) {
                return utType.preferredMIMEType
            }
        }

        let ext = pathExtension.lowercased()
        return MIMEType.forExtension(ext)
    }
}

private struct MIMEType {
    static func forExtension(_ ext: String) -> String? {
        let audioTypes: [String: String] = [
            "mp3": "audio/mpeg",
            "m4a": "audio/mp4",
            "m4b": "audio/mp4",
            "aac": "audio/aac",
            "flac": "audio/flac",
            "ogg": "audio/ogg",
            "opus": "audio/opus",
            "wav": "audio/wav",
            "wma": "audio/x-ms-wma",
            "aiff": "audio/aiff",
        ]
        return audioTypes[ext]
    }
}

extension SourceBookMetadata {
    func merging(with other: SourceBookMetadata?) -> SourceBookMetadata {
        guard let other = other else { return self }

        return SourceBookMetadata(
            title: self.title ?? other.title,
            author: self.author ?? other.author,
            narrator: self.narrator ?? other.narrator,
            description: self.description ?? other.description,
            coverURL: self.coverURL ?? other.coverURL,
            duration: self.duration ?? other.duration,
            chapters: self.chapters ?? other.chapters,
            series: self.series ?? other.series,
            seriesNumber: self.seriesNumber ?? other.seriesNumber,
            publishedYear: self.publishedYear ?? other.publishedYear,
            genres: self.genres ?? other.genres,
            publisher: self.publisher ?? other.publisher,
            isbn: self.isbn ?? other.isbn,
            asin: self.asin ?? other.asin
        )
    }

    static func fromFilename(_ filename: String) -> SourceBookMetadata {
        let name = (filename as NSString).deletingPathExtension

        if let separatorRange = name.range(of: " - ") {
            let author = String(name[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(name[separatorRange.upperBound...]).trimmingCharacters(in: .whitespaces)

            return SourceBookMetadata(
                title: title.isEmpty ? name : title,
                author: author.isEmpty ? nil : author,
                narrator: nil,
                description: nil,
                coverURL: nil,
                duration: nil,
                chapters: nil,
                series: nil,
                seriesNumber: nil,
                publishedYear: nil,
                genres: nil,
                publisher: nil,
                isbn: nil,
                asin: nil
            )
        }

        return SourceBookMetadata(
            title: name,
            author: nil,
            narrator: nil,
            description: nil,
            coverURL: nil,
            duration: nil,
            chapters: nil,
            series: nil,
            seriesNumber: nil,
            publishedYear: nil,
            genres: nil,
            publisher: nil,
            isbn: nil,
            asin: nil
        )
    }
}

extension BookSourceProvider {
    func handleHTTPResponse(
        _ response: URLResponse,
        data: Data,
        validStatusCodes: Range<Int> = 200..<300
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard validStatusCodes.contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw HTTPError.statusCode(httpResponse.statusCode, message: errorMessage)
        }
    }
}

enum HTTPError: LocalizedError {
    case statusCode(Int, message: String)

    var errorDescription: String? {
        switch self {
        case .statusCode(let code, let message):
            return "HTTP \(code): \(message)"
        }
    }
}

extension BookSourceProvider {
    func downloadFile(
        from url: URL,
        authHeader: String? = nil,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: url)
        if let authHeader = authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        let session = URLSession.shared
        let (localURL, response) = try await session.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw URLError(.badServerResponse)
        }

        return localURL
    }
}

extension BookSourceProvider {
    func log(_ message: String, level: LogLevel = .info) {
        let prefix: String
        switch level {
        case .debug: prefix = "🔍"
        case .info: prefix = "ℹ️"
        case .warning: prefix = "⚠️"
        case .error: prefix = "❌"
        }

        AppLogger.network.info("\(prefix) [\(displayName)] \(message)")
    }
}

enum LogLevel {
    case debug
    case info
    case warning
    case error
}

#if DEBUG
extension BookSourceProvider {
    static func mock(
        id: String = "mock",
        displayName: String = "Mock Provider",
        items: [RemoteItem] = []
    ) -> any BookSourceProvider {
        return MockBookSourceProvider(id: id, displayName: displayName, items: items)
    }
}

@MainActor
private final class MockBookSourceProvider: BookSourceProvider {
    let id: String
    let displayName: String
    let iconName = "folder"
    let capabilities: SourceCapabilities = [.folderBrowsing]

    @Published private(set) var authenticationState: AuthenticationState = .authenticated

    private let items: [RemoteItem]

    init(id: String, displayName: String, items: [RemoteItem]) {
        self.id = id
        self.displayName = displayName
        self.items = items
    }

    func authenticate() async throws {
        authenticationState = .authenticated
    }

    func refreshAuthentication() async throws {}

    func signOut() async throws {
        authenticationState = .notAuthenticated
    }

    func listRoot() async throws -> [RemoteItem] {
        return items
    }

    func listFolder(_ itemId: String) async throws -> [RemoteItem] {
        return items.filter { $0.parentId == itemId }
    }

    func search(_ query: String) async throws -> [RemoteItem] {
        return items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func resolveFile(_ item: RemoteItem) async throws -> ResolvedFile {
        return ResolvedFile(
            localURL: nil,
            streamURL: URL(string: "https://example.com/\(item.id)")!,
            expiresAt: nil,
            requiresAuthHeader: false,
            authHeaderValue: nil,
            contentLength: item.size
        )
    }

    func getMetadata(_ item: RemoteItem) async throws -> SourceBookMetadata? {
        return SourceBookMetadata.fromFilename(item.name)
    }
}
#endif

extension ISO8601DateFormatter {
    static let shared = ISO8601DateFormatter()

    static func parseFlexible(_ string: String) -> Date? {
        if let date = shared.date(from: string) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }

        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: string)
    }
}
