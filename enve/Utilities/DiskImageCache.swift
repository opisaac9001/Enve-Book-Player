import Combine
import ImageIO
import Logging
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit

extension NSImage {
    func jpegData(compressionQuality: Double) -> Data? {
        guard let tiffRepresentation = tiffRepresentation,
            let bitmapImage = NSBitmapImageRep(data: tiffRepresentation)
        else { return nil }
        return bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
#endif

class DiskImageCache {
    static let shared = DiskImageCache()
    private static let remoteFailureTTL: TimeInterval = 300

    private let cacheDirectory: URL
    private let memoryCache = NSCache<NSString, UIImage>()
    private let failedRemoteURLs = NSCache<NSString, NSDate>()

    init() {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("BookCovers")

        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = 96 * 1024 * 1024
    }

    private static func cost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        let size = image.size
        let scale = image.scale
        return Int(size.width * scale * size.height * scale * 4)
    }

    nonisolated static let coverMaxPixelSize: CGFloat = 1000

    nonisolated static func decodeDownsampled(_ data: Data, maxPixelSize: CGFloat = coverMaxPixelSize) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }

    func memoryImage(for url: URL?) -> UIImage? {
        guard let url = url else { return nil }
        return memoryCache.object(forKey: cacheKey(for: url) as NSString)
    }

    func image(for url: URL?) async -> UIImage? {
        guard let url = url else { return nil }
        let key = cacheKey(for: url) as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }
        let fileURL = cacheDirectory.appendingPathComponent(key as String)

        let image: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return Self.decodeDownsampled(data)
        }.value
        if let image {
            memoryCache.setObject(image, forKey: key, cost: Self.cost(of: image))
        }
        return image
    }

    func save(_ image: UIImage, for url: URL?) {
        guard let url = url else { return }
        let key = cacheKey(for: url) as NSString

        memoryCache.setObject(image, forKey: key, cost: Self.cost(of: image))

        let cacheDir = self.cacheDirectory
        let keyString = key as String
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }

        Task.detached(priority: .background) {
            let fileURL = cacheDir.appendingPathComponent(keyString)
            try? data.write(to: fileURL)
        }
    }

    func removeImage(for url: URL?) {
        guard let url = url else { return }
        let key = cacheKey(for: url) as NSString
        memoryCache.removeObject(forKey: key)
        let fileURL = cacheDirectory.appendingPathComponent(key as String)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func cacheKey(for url: URL) -> String {
        return Self.stableCacheKeyURLString(for: url).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
    }

    private static func stableCacheKeyURLString(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        let volatileQueryNames: Set<String> = [
            "token", "access_token", "auth", "authorization", "api_key", "apikey",
            "key", "signature", "sig", "expires", "expiry", "x-plex-token",
        ]
        if let queryItems = components.queryItems {
            let stableItems = queryItems.filter { !volatileQueryNames.contains($0.name.lowercased()) }
            components.queryItems = stableItems.isEmpty ? nil : stableItems
        }
        components.fragment = nil
        let stableURL = components.string ?? url.absoluteString
        if components.path.contains("/api/v1/media/book/") {
            return "grimmory-cover-v3|\(stableURL)"
        }
        return stableURL
    }

    func hasImage(for url: URL?) -> Bool {
        guard let url = url else { return false }
        let key = cacheKey(for: url)
        let fileURL = cacheDirectory.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    func clearMemoryCache() {
        memoryCache.removeAllObjects()
        AppLogger.library.info("Memory cache cleared")
    }

    func shouldSkipRemoteFetch(for url: URL) -> Bool {
        let key = cacheKey(for: url) as NSString
        guard let expiry = failedRemoteURLs.object(forKey: key) as Date? else {
            return false
        }
        if expiry > Date() {
            return true
        }
        failedRemoteURLs.removeObject(forKey: key)
        return false
    }

    func markRemoteFetchFailure(for url: URL) {
        let key = cacheKey(for: url) as NSString
        failedRemoteURLs.setObject(NSDate(timeIntervalSinceNow: Self.remoteFailureTTL), forKey: key)
    }

    func clearRemoteFetchFailure(for url: URL) {
        let key = cacheKey(for: url) as NSString
        failedRemoteURLs.removeObject(forKey: key)
    }

    func clearAllCache() {
        memoryCache.removeAllObjects()
        failedRemoteURLs.removeAllObjects()

        Task.detached(priority: .background) {
            do {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: self.cacheDirectory.path) {
                    let contents = try fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: nil)
                    for file in contents {
                        try fileManager.removeItem(at: file)
                    }
                }
                AppLogger.library.info("All cache cleared (memory + disk)")
            } catch {
                AppLogger.library.error("Error clearing disk cache: \(error)")
            }
        }
    }
}

#if os(iOS)
struct CachedAsyncCoverImage: View {
    private static let remoteSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "User-Agent":
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        ]
        return URLSession(configuration: config)
    }()

    let url: URL?
    let fallbackColor: String
    var headers: [String: String] = [:]

    var book: Book? = nil
    @State private var image: UIImage?
    @State private var isLoading = false

    private var reloadKey: String {
        let urlKey = url?.absoluteString ?? "<nil-url>"
        let thumbKey = book?.thumb ?? "<nil-thumb>"
        let bookKey = book?.downloadKey ?? "<nil-book>"
        return [urlKey, thumbKey, bookKey].joined(separator: "|")
    }

    var body: some View {
        Group {
            if let image = image {
                #if os(macOS)
                Image(nsImage: image)
                    .resizable()
                #else
                Image(uiImage: image)
                    .resizable()
                #endif
            } else if url != nil {
                ZStack {
                    CoverImage(colorName: fallbackColor)
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                }
            } else if book != nil {
                ZStack {
                    CoverImage(colorName: fallbackColor)
                }
            } else {
                CoverImage(colorName: fallbackColor)
            }
        }
        .task(id: reloadKey) {
            image = nil
            isLoading = false

            if let url {
                await loadImage(from: url)
            } else if let book {
                await loadFromPersistentStorage(book: book)
            }
        }
    }

    private func loadFromPersistentStorage(book: Book) async {
        let coverPath = LocalStorageManager.shared.coverOverridePath(for: book.downloadKey)
        let prepared: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: coverPath) else { return nil }
            return DiskImageCache.decodeDownsampled(data)
        }.value
        if let img = prepared {
            self.image = img
        }
    }

    private func loadImage(from url: URL) async {

        if let cached = DiskImageCache.shared.memoryImage(for: url) {
            self.image = cached
            return
        }

        if let cached = await DiskImageCache.shared.image(for: url) {
            self.image = cached
            return
        }

        let identityBook = book
        if let identityBook {
            let coverPath = LocalStorageManager.shared.coverOverridePath(for: identityBook.downloadKey)
            let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: coverPath) else { return nil }
                return DiskImageCache.decodeDownsampled(data)
            }.value
            if let img = decoded {
                DiskImageCache.shared.save(img, for: url)
                if let data = img.jpegData(compressionQuality: 0.9) {
                    await AppCache.shared.setCoverData(data, for: identityBook)
                }
                self.image = img
                return
            }
        }

        let isLocalPath = url.isFileURL || (url.scheme == nil && url.path.hasPrefix("/"))
        if isLocalPath {
            let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
            let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return DiskImageCache.decodeDownsampled(data)
            }.value
            if let img = decoded {
                DiskImageCache.shared.save(img, for: url)
                if let bookRef = identityBook, let data = img.jpegData(compressionQuality: 0.9) {
                    await AppCache.shared.setCoverData(data, for: bookRef)
                }
                self.image = img
            }
            return
        }

        isLoading = true

        if let identityBook, identityBook.source == .storyteller {
            let provider = await MainActor.run { AppState.shared.getProvider(identityBook.providerId) as? StorytellerProvider }
            if let provider {
                do {
                    if let data = try await provider.fetchCoverImage(for: identityBook),
                        let img = await Self.decodeOffMain(data)
                    {
                        DiskImageCache.shared.save(img, for: url)
                        DiskImageCache.shared.clearRemoteFetchFailure(for: url)
                        await AppCache.shared.setCoverData(data, for: identityBook)
                        _ = try? LocalStorageManager.shared.saveCoverOverride(for: identityBook.downloadKey, imageData: data)
                        await MainActor.run {
                            self.image = img
                            self.isLoading = false
                        }
                    } else {
                        DiskImageCache.shared.markRemoteFetchFailure(for: url)
                        await MainActor.run { isLoading = false }
                    }
                } catch {
                    if Self.isCancellationError(error) {
                        await MainActor.run { isLoading = false }
                        return
                    }
                    AppLogger.library.error(
                        "[CoverImage] Storyteller cover fetch failed for \(identityBook.id): \(error.localizedDescription)"
                    )
                    DiskImageCache.shared.markRemoteFetchFailure(for: url)
                    await MainActor.run { isLoading = false }
                }
                return
            }
        }

        if DiskImageCache.shared.shouldSkipRemoteFetch(for: url) {
            await MainActor.run { isLoading = false }
            return
        }

        let bookloreProvider = await MainActor.run {
            AppState.shared.providerConnections.bookloreProvider(for: url)
        }
        if let provider = bookloreProvider {
            do {
                let (data, httpStatus) = try await provider.fetchImageData(url: url)
                if let img = await Self.decodeOffMain(data) {
                    DiskImageCache.shared.save(img, for: url)
                    if let bookRef = book {
                        await AppCache.shared.setCoverData(data, for: bookRef)
                        _ = try? LocalStorageManager.shared.saveCoverOverride(for: bookRef.downloadKey, imageData: data)
                    }
                    await MainActor.run {
                        self.image = img; self.isLoading = false
                    }
                } else {
                    AppLogger.library.info("[CoverImage] Booklore non-image (HTTP \(httpStatus), \(data.count) bytes) for \(url.redacted)")
                    await MainActor.run { isLoading = false }
                }
            } catch {
                if Self.isCancellationError(error) {
                    await MainActor.run { isLoading = false }
                    return
                }
                AppLogger.library.error("[CoverImage] Booklore fetch failed for \(url.redacted): \(error.localizedDescription)")
                await MainActor.run { isLoading = false }
            }
            return
        }

        let opdsConnection = await MainActor.run { AppState.shared.opdsConnection(for: url) }
        if let conn = opdsConnection {
            let provider = OPDSProvider(connection: conn)
            do {
                let data = try await provider.fetchCoverImage(url: url)
                if let img = await Self.decodeOffMain(data) {
                    DiskImageCache.shared.save(img, for: url)
                    if let bookRef = book {
                        await AppCache.shared.setCoverData(data, for: bookRef)
                        _ = try? LocalStorageManager.shared.saveCoverOverride(for: bookRef.downloadKey, imageData: data)
                    }
                    await MainActor.run {
                        self.image = img; self.isLoading = false
                    }
                } else {
                    await MainActor.run { isLoading = false }
                }
            } catch {
                if Self.isCancellationError(error) {
                    await MainActor.run { isLoading = false }
                    return
                }
                AppLogger.library.error("[CoverImage] OPDS fetch failed for \(url.redacted): \(error.localizedDescription)")
                await MainActor.run { isLoading = false }
            }
            return
        }

        let candidateURLs = Self.remoteCandidateURLs(for: url)
        for attempt in 0..<2 {
            if attempt == 1 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            let currentHeaders: [String: String]
            if attempt == 0 {
                currentHeaders = headers
            } else {
                currentHeaders = await MainActor.run { Self.freshHeaders(for: url, fallback: headers) }
            }

            for candidateURL in candidateURLs {
                do {
                    var request = URLRequest(url: candidateURL)
                    for (key, value) in currentHeaders {
                        request.setValue(value, forHTTPHeaderField: key)
                    }

                    let (data, response) = try await Self.remoteSession.data(for: request)
                    let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

                    if httpStatus == 401 && attempt == 0 {
                        break
                    }

                    if httpStatus == 404 && candidateURL != candidateURLs.last {
                        continue
                    }

                    if let downloadedImage = await Self.decodeOffMain(data) {
                        DiskImageCache.shared.save(downloadedImage, for: url)
                        if candidateURL != url {
                            DiskImageCache.shared.save(downloadedImage, for: candidateURL)
                        }
                        DiskImageCache.shared.clearRemoteFetchFailure(for: url)
                        DiskImageCache.shared.clearRemoteFetchFailure(for: candidateURL)
                        if let bookRef = book {
                            await AppCache.shared.setCoverData(data, for: bookRef)
                            _ = try? LocalStorageManager.shared.saveCoverOverride(for: bookRef.downloadKey, imageData: data)
                        }
                        await MainActor.run {
                            self.image = downloadedImage
                            self.isLoading = false
                        }
                        return
                    }

                    if candidateURL != candidateURLs.last {
                        continue
                    }

                    AppLogger.library.info(
                        "[CoverImage] Non-image response (HTTP \(httpStatus), \(data.count) bytes) for \(candidateURL.redacted)"
                    )
                    DiskImageCache.shared.markRemoteFetchFailure(for: url)
                    DiskImageCache.shared.markRemoteFetchFailure(for: candidateURL)
                    await MainActor.run { isLoading = false }
                    return
                } catch {
                    if Self.isCancellationError(error) {
                        await MainActor.run { isLoading = false }
                        return
                    }
                    if candidateURL != candidateURLs.last {
                        continue
                    }
                    AppLogger.library.error("[CoverImage] Download failed for \(candidateURL.redacted): \(error.localizedDescription)")
                    DiskImageCache.shared.markRemoteFetchFailure(for: url)
                    DiskImageCache.shared.markRemoteFetchFailure(for: candidateURL)
                    await MainActor.run { isLoading = false }
                    return
                }
            }
        }
        DiskImageCache.shared.markRemoteFetchFailure(for: url)
        await MainActor.run { isLoading = false }
    }

    @MainActor
    private static func remoteCandidateURLs(for url: URL) -> [URL] {
        guard let fallback = storytellerAudioFallbackURL(from: url), fallback != url else {
            return [url]
        }
        return [url, fallback]
    }

    @MainActor
    private static func storytellerAudioFallbackURL(from url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
            AppState.shared.providerConnections.connections.contains(where: {
                $0.type == .storyteller && URL(string: $0.url)?.host?.lowercased() == host
            }),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.path.contains("/api/v2/books/"),
            components.path.hasSuffix("/cover")
        else {
            return nil
        }

        var queryItems = components.queryItems ?? []
        if queryItems.contains(where: { $0.name == "audio" && $0.value == "true" }) {
            return nil
        }
        if !queryItems.contains(where: { $0.name == "w" }) {
            queryItems.append(URLQueryItem(name: "w", value: "400"))
        }
        if !queryItems.contains(where: { $0.name == "h" }) {
            queryItems.append(URLQueryItem(name: "h", value: "640"))
        }
        queryItems.append(URLQueryItem(name: "audio", value: "true"))
        components.queryItems = queryItems
        return components.url
    }

    @MainActor
    static func webDAVHeaders(for book: Book) -> [String: String] {
        return authHeaders(for: book)
    }

    @MainActor
    static func authHeaders(for book: Book) -> [String: String] {
        guard let connection = AppState.shared.providerConnections.connections.first(where: { $0.id == book.providerId }) else {
            return [:]
        }
        var headers: [String: String] = [:]

        if let custom = connection.customHeaders {
            for (key, value) in custom {
                headers[key] = value
            }
        }

        let token =
            connection.token
            ?? (connection.type == .silo ? SharedKeychainStore.shared.token(forConnectionId: connection.id.uuidString) : nil)

        if connection.type == .silo,
            let token,
            !token.isEmpty
        {
            headers["Authorization"] = token.hasPrefix("Bearer ") ? token : "Bearer \(token)"
        } else if connection.authMode == .usernamePassword || connection.authMode == .auto,
            let username = connection.username,
            let password = connection.password,
            !username.isEmpty
        {
            let credentials = "\(username):\(password)"
            if let data = credentials.data(using: .utf8) {
                headers["Authorization"] = "Basic \(data.base64EncodedString())"
            }
        } else if let token, !token.isEmpty {
            if token.hasPrefix("Basic ") || token.hasPrefix("Bearer ") {
                headers["Authorization"] = token
            } else if connection.type == .jellyfin || connection.type == .emby {
                headers["X-Emby-Token"] = token
            } else if connection.type == .audiobookshelf || connection.type == .booklore || connection.type == .storyteller
                || connection.type == .bookOrbit || connection.type == .silo || connection.authMode == .sso
            {
                headers["Authorization"] = "Bearer \(token)"
            } else {
                headers["X-API-Key"] = token
            }
        }

        return headers
    }

    @MainActor
    static func freshHeaders(for url: URL, fallback: [String: String]) -> [String: String] {
        guard let host = url.host?.lowercased() else { return fallback }
        let port = resolvedPort(for: url)
        guard
            let connection = AppState.shared.providerConnections.connections.first(where: {
                guard let connectionURL = URL(string: $0.url) else { return false }
                return connectionURL.host?.lowercased() == host && resolvedPort(for: connectionURL) == port
            })
        else { return fallback }

        var headers: [String: String] = [:]
        if let custom = connection.customHeaders {
            for (key, value) in custom { headers[key] = value }
        }
        let token =
            connection.token
            ?? (connection.type == .silo ? SharedKeychainStore.shared.token(forConnectionId: connection.id.uuidString) : nil)
        if let token, !token.isEmpty {
            if token.hasPrefix("Basic ") {
                headers["Authorization"] = token
            } else if connection.type == .jellyfin || connection.type == .emby {
                headers["X-Emby-Token"] = token
            } else if connection.type == .audiobookshelf || connection.type == .booklore || connection.type == .storyteller
                || connection.type == .bookOrbit || connection.type == .silo
            {
                headers["Authorization"] = "Bearer \(token)"
            } else {
                headers["X-API-Key"] = token
            }
        } else if let username = connection.username, let password = connection.password, !username.isEmpty {
            let credentials = "\(username):\(password)"
            if let data = credentials.data(using: .utf8) {
                headers["Authorization"] = "Basic \(data.base64EncodedString())"
            }
        }
        return headers
    }

    private static func resolvedPort(for url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }

    private static func decodeOffMain(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            DiskImageCache.decodeDownsampled(data)
        }.value
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }

        return false
    }
}
#endif
