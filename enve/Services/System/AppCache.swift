import CryptoKit
import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
import CoreGraphics
#endif

enum CacheScope: Equatable {
    case local
    case iCloudIfAvailable
}

actor DiskDataCache {
    private let directory: URL
    private let memoryCache = NSCache<NSString, NSData>()

    init(directory: URL, memoryLimitBytes: Int = 64 * 1024 * 1024) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memoryCache.totalCostLimit = memoryLimitBytes
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(forKey key: String, fileExtension: String) -> URL {
        let safe = Self.sha256Hex(key)
        return directory.appendingPathComponent(safe).appendingPathExtension(fileExtension)
    }

    func getData(forKey key: String, fileExtension: String = "dat") -> Data? {
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached as Data
        }

        let url = fileURL(forKey: key, fileExtension: fileExtension)
        guard let data = try? Data(contentsOf: url) else { return nil }
        memoryCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    func setData(_ data: Data, forKey key: String, fileExtension: String = "dat") {
        memoryCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)

        let url = fileURL(forKey: key, fileExtension: fileExtension)
        try? data.write(to: url, options: [.atomic])
    }

    func removeData(forKey key: String, fileExtension: String = "dat") {
        memoryCache.removeObject(forKey: key as NSString)
        let url = fileURL(forKey: key, fileExtension: fileExtension)
        try? FileManager.default.removeItem(at: url)
    }

    func totalDiskBytes() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true,
                let fileSize = values.fileSize
            else {
                continue
            }
            total += Int64(fileSize)
        }
        return total
    }

    func clearAll() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

actor DiskCodableCache {
    private let directory: URL
    private static let envelopeMarker = Data("ENVE-CODABLE-CACHE-V2\n".utf8)
    private static let newline: UInt8 = 10

    private struct EnvelopeHeader: Codable {
        let savedAt: String
    }

    private struct PayloadEnvelope {
        let savedAt: Date
        let payload: Data
        let isLegacy: Bool
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(forKey key: String) -> URL {
        let safe = Self.sha256Hex(key)
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }

    func load<T: Codable & Sendable>(_ type: T.Type, key: String, maxAge: TimeInterval?) -> T? {
        loadDecoded(type, key: key, maxAge: maxAge)
    }

    func loadDecoded<T: Codable & Sendable>(_ type: T.Type, key: String, maxAge: TimeInterval?) -> T? {
        guard let payload = loadPayload(key: key, maxAge: maxAge) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: payload)
    }

    func save<T: Codable & Sendable>(_ value: T, key: String) {
        let url = fileURL(forKey: key)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let valueData = try? encoder.encode(value),
            let data = Self.makeEnvelopeData(payload: valueData, savedAt: Date())
        else {
            return
        }

        try? data.write(to: url, options: [.atomic])
    }

    func loadRawData(key: String, maxAge: TimeInterval?) -> Data? {
        loadPayload(key: key, maxAge: maxAge)
    }

    func saveRawData(_ data: Data, key: String) {
        let url = fileURL(forKey: key)
        guard let rootData = Self.makeEnvelopeData(payload: data, savedAt: Date()) else {
            return
        }

        try? rootData.write(to: url, options: [.atomic])
    }

    private func loadPayload(key: String, maxAge: TimeInterval?) -> Data? {
        let url = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: url),
            let envelope = Self.parseEnvelope(data)
        else {
            return nil
        }

        if let maxAge {
            let age = Date().timeIntervalSince(envelope.savedAt)
            guard age <= maxAge else { return nil }
        }

        if envelope.isLegacy,
            let rewritten = Self.makeEnvelopeData(payload: envelope.payload, savedAt: envelope.savedAt)
        {
            try? rewritten.write(to: url, options: [.atomic])
        }

        return envelope.payload
    }

    private static func makeEnvelopeData(payload: Data, savedAt: Date) -> Data? {
        let encoder = JSONEncoder()
        guard let header = try? encoder.encode(EnvelopeHeader(savedAt: isoFormatter.string(from: savedAt))) else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(envelopeMarker.count + header.count + 1 + payload.count)
        data.append(envelopeMarker)
        data.append(header)
        data.append(contentsOf: [newline])
        data.append(payload)
        return data
    }

    private static func parseEnvelope(_ data: Data) -> PayloadEnvelope? {
        if let current = parseCurrentEnvelope(data) {
            return current
        }
        return parseLegacyEnvelope(data)
    }

    private static func parseCurrentEnvelope(_ data: Data) -> PayloadEnvelope? {
        guard data.count > envelopeMarker.count,
            data.prefix(envelopeMarker.count).elementsEqual(envelopeMarker)
        else {
            return nil
        }

        let headerStart = data.index(data.startIndex, offsetBy: envelopeMarker.count)
        guard let headerEnd = data[headerStart...].firstIndex(of: newline) else {
            return nil
        }

        let payloadStart = data.index(after: headerEnd)
        guard payloadStart <= data.endIndex else {
            return nil
        }

        let headerData = data[headerStart..<headerEnd]
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(EnvelopeHeader.self, from: Data(headerData)),
            let savedAt = isoFormatter.date(from: header.savedAt)
        else {
            return nil
        }

        return PayloadEnvelope(
            savedAt: savedAt,
            payload: Data(data[payloadStart..<data.endIndex]),
            isLegacy: false
        )
    }

    private static func parseLegacyEnvelope(_ data: Data) -> PayloadEnvelope? {
        guard let rootAny = try? JSONSerialization.jsonObject(with: data),
            let root = rootAny as? [String: Any],
            let savedAtString = root["savedAt"] as? String,
            let savedAt = isoFormatter.date(from: savedAtString),
            let valueAny = root["value"],
            JSONSerialization.isValidJSONObject(valueAny),
            let payload = try? JSONSerialization.data(withJSONObject: valueAny)
        else {
            return nil
        }

        return PayloadEnvelope(savedAt: savedAt, payload: payload, isLegacy: true)
    }

    func remove(key: String) {
        let url = fileURL(forKey: key)
        try? FileManager.default.removeItem(at: url)
    }

    func totalDiskBytes() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true,
                let fileSize = values.fileSize
            else {
                continue
            }
            total += Int64(fileSize)
        }
        return total
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

actor AppCache {
    static let shared = AppCache()

    private var preferredScope: CacheScope

    private let localCovers: DiskDataCache
    private let localMetadata: DiskCodableCache

    private var iCloudCovers: DiskDataCache?

    init() {
        let localBase =
            AppCache.localBaseURL() ?? FileManager.default.temporaryDirectory.appendingPathComponent("EnveCache", isDirectory: true)
        let localCoversDir = localBase.appendingPathComponent("covers", isDirectory: true)
        let localMetadataDir = localBase.appendingPathComponent("metadata", isDirectory: true)

        self.localCovers = DiskDataCache(directory: localCoversDir)
        self.localMetadata = DiskCodableCache(directory: localMetadataDir)
        self.iCloudCovers = nil

        let savedScopeRaw = UserDefaults.standard.string(forKey: "cacheScopePreference")
        let isICloud = savedScopeRaw == "iCloudIfAvailable"
        self.preferredScope = isICloud ? .iCloudIfAvailable : .local

        Task {
            await migrateFromOldCacheLocation(to: localBase, coversDir: localCoversDir, metadataDir: localMetadataDir)
            if isICloud {
                await ensureICloudCachesIfNeeded()
            }
        }
    }

    private static func localBaseURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EnveCache", isDirectory: true)
    }

    private static func oldCacheBaseURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EnveCache", isDirectory: true)
    }

    private func migrateFromOldCacheLocation(to newBase: URL, coversDir: URL, metadataDir: URL) async {
        let migrationKey = "AppCacheMigrationToApplicationSupport"
        if UserDefaults.standard.bool(forKey: migrationKey) {
            return
        }

        guard let oldBase = Self.oldCacheBaseURL() else { return }
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: oldBase.path) else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        let oldCoversDir = oldBase.appendingPathComponent("covers", isDirectory: true)
        let oldMetadataDir = oldBase.appendingPathComponent("metadata", isDirectory: true)

        AppLogger.network.info("Migrating cache data from Caches to Application Support directory...")

        try? fileManager.createDirectory(at: coversDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: metadataDir, withIntermediateDirectories: true)

        var migratedFiles = 0

        if fileManager.fileExists(atPath: oldCoversDir.path) {
            if let files = try? fileManager.contentsOfDirectory(at: oldCoversDir, includingPropertiesForKeys: nil) {
                for file in files {
                    let destination = coversDir.appendingPathComponent(file.lastPathComponent)
                    if !fileManager.fileExists(atPath: destination.path) {
                        try? fileManager.moveItem(at: file, to: destination)
                        migratedFiles += 1
                    }
                }
            }
        }

        if fileManager.fileExists(atPath: oldMetadataDir.path) {
            if let files = try? fileManager.contentsOfDirectory(at: oldMetadataDir, includingPropertiesForKeys: nil) {
                for file in files {
                    let destination = metadataDir.appendingPathComponent(file.lastPathComponent)
                    if !fileManager.fileExists(atPath: destination.path) {
                        try? fileManager.moveItem(at: file, to: destination)
                        migratedFiles += 1
                    }
                }
            }
        }

        if let contents = try? fileManager.contentsOfDirectory(at: oldBase, includingPropertiesForKeys: nil),
            contents.isEmpty
        {
            try? fileManager.removeItem(at: oldBase)
        }

        UserDefaults.standard.set(true, forKey: migrationKey)

        if migratedFiles > 0 {
            AppLogger.network.info("Migrated \(migratedFiles) cache files to Application Support directory")
        } else {
            AppLogger.network.info("No cache files to migrate")
        }
    }

    private static func iCloudBaseURLIfAvailable() async -> URL? {
        await Task.detached(priority: .utility) {
            guard let ubiquity = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
                return nil
            }
            return
                ubiquity
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("NarratarrCache", isDirectory: true)
        }.value
    }

    private func ensureICloudCachesIfNeeded() async {
        guard iCloudCovers == nil else { return }
        guard let iCloudBase = await Self.iCloudBaseURLIfAvailable() else { return }

        let coversDir = iCloudBase.appendingPathComponent("covers", isDirectory: true)
        iCloudCovers = DiskDataCache(directory: coversDir)
    }

    func setPreferredScope(_ scope: CacheScope) async {
        preferredScope = scope
        if case .iCloudIfAvailable = scope {
            await ensureICloudCachesIfNeeded()
        }
    }

    private func activeCoversCache() async -> DiskDataCache {
        switch preferredScope {
        case .local:
            return localCovers
        case .iCloudIfAvailable:
            await ensureICloudCachesIfNeeded()
            return iCloudCovers ?? localCovers
        }
    }

    private nonisolated static func makeCoverThumbnailData(
        from original: Data,
        maxPixel: CGFloat = 600,
        jpegQuality: CGFloat = 0.82
    ) -> Data {
        #if canImport(UIKit)
        guard let image = UIImage(data: original) else { return original }

        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let maxSide = max(pixelWidth, pixelHeight)

        guard maxSide > maxPixel, maxSide > 0 else {
            return image.jpegData(compressionQuality: jpegQuality) ?? original
        }

        let scaleFactor = maxPixel / maxSide
        let targetSize = CGSize(
            width: floor(image.size.width * scaleFactor),
            height: floor(image.size.height * scaleFactor)
        )

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        return resized.jpegData(compressionQuality: jpegQuality) ?? original
        #else
        return original
        #endif
    }

    func coverCacheKey(for book: Book) -> String {
        if let backendId = book.backendId {
            return "cover-\(book.source.rawValue)-\(backendId)-\(book.id)"
        }
        return "cover-\(book.source.rawValue)-\(book.id)"
    }

    func getCoverData(for book: Book) async -> Data? {
        let cache = await activeCoversCache()
        return await cache.getData(forKey: coverCacheKey(for: book))
    }

    func setCoverData(_ data: Data, for book: Book) async {
        let prefs = await Task { @MainActor in
            LibraryDisplayPreferencesStore.shared.loadPreferences()
        }.value
        let finalData: Data

        if prefs.compressCoversEnabled {
            finalData = Self.makeCoverThumbnailData(from: data)
        } else {
            finalData = data
        }

        let cache = await activeCoversCache()
        await cache.setData(finalData, forKey: coverCacheKey(for: book))
    }

    func removeCoverData(for book: Book) async {
        let cache = await activeCoversCache()
        await cache.removeData(forKey: coverCacheKey(for: book))
    }

    func loadCodable<T: Codable & Sendable>(_ type: T.Type, key: String, maxAge: TimeInterval? = nil) async -> T? {
        return await localMetadata.load(type, key: key, maxAge: maxAge)
    }

    func saveCodable<T: Codable & Sendable>(_ value: T, key: String) async {
        await localMetadata.save(value, key: key)
    }

    @MainActor
    func loadCodableMainActor<T: Codable>(_ type: T.Type, key: String, maxAge: TimeInterval? = nil) async -> T? {
        guard let rawData = await localMetadata.loadRawData(key: key, maxAge: maxAge) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: rawData)
    }

    @MainActor
    func saveCodableMainActor<T: Codable>(_ value: T, key: String) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        await localMetadata.saveRawData(data, key: key)
    }

    func removeCodable(key: String) async {
        await localMetadata.remove(key: key)
    }

    func activeCacheSizes() async -> (coversBytes: Int64, metadataBytes: Int64) {
        let coversCache = await activeCoversCache()
        async let covers = coversCache.totalDiskBytes()
        async let metadata = localMetadata.totalDiskBytes()
        return await (coversBytes: covers, metadataBytes: metadata)
    }

    func getCachedCoverCount(for books: [Book]) async -> Int {
        var count = 0
        for book in books {
            if await getCoverData(for: book) != nil {
                count += 1
            }
        }
        return count
    }

    func cacheAllCovers(for books: [Book], progress: @Sendable @escaping (Int, Int) async -> Void) async throws {
        let booksWithCovers = books.filter { $0.thumb != nil }
        let total = booksWithCovers.count

        for (index, book) in booksWithCovers.enumerated() {
            try Task.checkCancellation()

            if await getCoverData(for: book) != nil {
                await progress(index + 1, total)
                continue
            }

            guard let thumb = book.thumb,
                let url = URL(string: thumb)
            else {
                await progress(index + 1, total)
                continue
            }

            do {
                let (data, response) = try await InsecureURLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    await setCoverData(data, for: book)
                }
            } catch {
                AppLogger.network.error(
                    "Failed to cache cover bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error)"
                )
            }

            await progress(index + 1, total)
        }
    }

    func clearActiveCaches() async {
        await activeCoversCache().clearAll()
        await localMetadata.clearAll()
    }

    func clearCoverCache() async {
        await activeCoversCache().clearAll()
    }

    func runMaintenance() async {
        let prefs = await Task { @MainActor in
            LibraryDisplayPreferencesStore.shared.loadPreferences()
        }.value

        if prefs.autoClearCacheEnabled {
            let thresholdBytes: Int64 = 1024 * 1024 * 1024
            if let available = getAvailableDiskSpace(), available < thresholdBytes {
                AppLogger.network.info("Low storage detected (\(available / 1024 / 1024)MB). Auto-clearing caches...")
                await clearActiveCaches()
            }
        }

        if prefs.expireOldMetadataEnabled {
            let maxAge: TimeInterval = 30 * 24 * 60 * 60
            await cleanExpiredMetadata(maxAge: maxAge)
        }
    }

    private func getAvailableDiskSpace() -> Int64? {
        let fileManager = FileManager.default
        let path = NSHomeDirectory()
        do {
            let values = try fileManager.attributesOfFileSystem(forPath: path)
            if let freeSpace = values[.systemFreeSize] as? Int64 {
                return freeSpace
            }
        } catch {
            AppLogger.network.error("Failed to get disk space: \(error)")
        }
        return nil
    }

    private func cleanExpiredMetadata(maxAge: TimeInterval) async {
        AppLogger.network.warning("Checking for expired metadata (older than 30 days)...")
    }
}
