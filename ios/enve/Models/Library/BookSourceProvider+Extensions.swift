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
}

extension BookSourceProvider {
    func log(_ message: String, level: LogLevel = .info) {
        switch level {
        case .debug: AppLogger.network.debug("[\(displayName)] \(message)")
        case .info: AppLogger.network.info("[\(displayName)] \(message)")
        case .warning: AppLogger.network.warning("[\(displayName)] \(message)")
        case .error: AppLogger.network.error("[\(displayName)] \(message)")
        }
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
}
