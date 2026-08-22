import Foundation
import Logging

actor MetadataStorage {
    static let shared = MetadataStorage()

    private let fileManager = FileManager.default

    private init() {
        try? Self.createMetadataDirectoryIfNeeded(using: fileManager)
    }

    nonisolated private static func decodeMetadata(_ data: Data) throws -> BookMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BookMetadata.self, from: data)
    }

    nonisolated private static func encodeMetadata(_ metadata: BookMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(metadata)
    }

    private nonisolated static func metadataDirectoryURL(using fileManager: FileManager) throws -> URL {
        let documentsURL = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documentsURL.appendingPathComponent("Metadata", isDirectory: true)
    }

    private nonisolated static func createMetadataDirectoryIfNeeded(using fileManager: FileManager) throws {
        let metadataURL = try metadataDirectoryURL(using: fileManager)

        if !fileManager.fileExists(atPath: metadataURL.path) {
            try fileManager.createDirectory(
                at: metadataURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            AppLogger.network.debug(
                "Created metadata directory pathId=\(DiagnosticLogSanitizer.identifier(for: metadataURL.standardizedFileURL.path))"
            )
        }
    }

    nonisolated func recoverMisplacedMetadataDirectory() {
        let fm = FileManager.default
        do {
            let metadataURL = try Self.metadataDirectoryURL(using: fm)
            if fm.fileExists(atPath: metadataURL.path) { return }

            let documentsURL = metadataURL.deletingLastPathComponent()
            let canonicalRoot = documentsURL.appendingPathComponent("Individual_Audiobooks", isDirectory: true)
            guard fm.fileExists(atPath: canonicalRoot.path) else { return }

            let candidates =
                (try? fm.contentsOfDirectory(
                    at: canonicalRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []

            for candidate in candidates {
                let isDir = (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir, candidate.lastPathComponent.hasPrefix("Metadata") else { continue }

                let jsonFiles =
                    (try? fm.contentsOfDirectory(
                        at: candidate,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ).filter { $0.pathExtension == "json" }) ?? []

                guard !jsonFiles.isEmpty else { continue }

                AppLogger.network.warning(
                    "Recovering misplaced metadata \(DiagnosticLogSanitizer.fileDescriptor(for: candidate))"
                )
                do {
                    try fm.moveItem(at: candidate, to: metadataURL)
                    AppLogger.network.info("Recovered \(jsonFiles.count) metadata files to Documents/Metadata/")
                    return
                } catch {
                    AppLogger.network.error("Recovery move failed: \(error) - will recreate directory")
                }
            }
        } catch {
            AppLogger.network.error("Could not check for misplaced Metadata directory: \(error)")
        }
    }

    private nonisolated static func metadataFileURL(bookId: String, using fileManager: FileManager) throws -> URL {
        let metadataDir = try metadataDirectoryURL(using: fileManager)
        var sanitizedId =
            bookId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "*", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "<", with: "_")
            .replacingOccurrences(of: ">", with: "_")
            .replacingOccurrences(of: "|", with: "_")
        if sanitizedId.count > 200 {
            sanitizedId = String(sanitizedId.prefix(200))
        }
        return metadataDir.appendingPathComponent("\(sanitizedId).json")
    }

    private nonisolated static func alternateBookIds(for bookId: String) -> [String] {
        var alternates: [String] = []

        if bookId.contains(":") {
            let parts = bookId.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let hash = String(parts[1])
                alternates.append("local-\(hash)")
                alternates.append("canonical:\(hash)")
                alternates.append("file-sharing:\(hash)")
            }
        }

        if bookId.hasPrefix("local-") {
            let hash = String(bookId.dropFirst(6))
            alternates.append("file-sharing:\(hash)")
            alternates.append("canonical:\(hash)")
        }

        if bookId.hasPrefix("canonical:") {
            let hash = String(bookId.dropFirst(10))
            alternates.append("file-sharing:\(hash)")
            alternates.append("local-\(hash)")
        }

        return alternates
    }

    func loadMetadata(bookId: String) async throws -> BookMetadata? {
        let fileURL = try Self.metadataFileURL(bookId: bookId, using: fileManager)

        if fileManager.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            return try Self.decodeMetadata(data)
        }

        for alternateId in Self.alternateBookIds(for: bookId) {
            let alternateURL = try Self.metadataFileURL(bookId: alternateId, using: fileManager)
            if fileManager.fileExists(atPath: alternateURL.path) {
                AppLogger.network.debug(
                    "Found alternate metadata sourceId=\(DiagnosticLogSanitizer.identifier(for: alternateId)) bookId=\(DiagnosticLogSanitizer.identifier(for: bookId))"
                )
                let data = try Data(contentsOf: alternateURL)
                var metadata = try Self.decodeMetadata(data)
                metadata.bookId = bookId
                try await saveMetadata(metadata)
                try? fileManager.removeItem(at: alternateURL)
                AppLogger.network.debug(
                    "Migrated alternate metadata sourceId=\(DiagnosticLogSanitizer.identifier(for: alternateId)) bookId=\(DiagnosticLogSanitizer.identifier(for: bookId))"
                )
                return metadata
            }
        }

        return nil
    }

    func saveMetadata(_ metadata: BookMetadata) async throws {
        var updated = metadata
        updated.metadataVersion = "1.0"
        updated.lastUpdated = Date()
        let bookId = updated.bookId
        let data = try Self.encodeMetadata(updated)

        try Self.createMetadataDirectoryIfNeeded(using: fileManager)

        let fileURL = try Self.metadataFileURL(bookId: bookId, using: fileManager)

        try data.write(to: fileURL, options: [.atomic])

        AppLogger.network.debug(
            "Saved metadata bookId=\(DiagnosticLogSanitizer.identifier(for: bookId))"
        )
    }

    func deleteMetadata(bookId: String) async throws {
        let fileURL = try Self.metadataFileURL(bookId: bookId, using: fileManager)

        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
            AppLogger.network.debug(
                "Deleted metadata bookId=\(DiagnosticLogSanitizer.identifier(for: bookId))"
            )
        }
    }

    nonisolated func loadAllMetadata() async throws -> [String: BookMetadata] {
        let fm = FileManager.default
        let metadataDir = try Self.metadataDirectoryURL(using: fm)
        guard fm.fileExists(atPath: metadataDir.path) else { return [:] }
        let urls = try fm.contentsOfDirectory(
            at: metadataDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        return await withTaskGroup(of: BookMetadata?.self) { group in
            let concurrency = 16
            var iter = urls.makeIterator()
            for _ in 0..<concurrency {
                guard let url = iter.next() else { break }
                group.addTask {
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? Self.decodeMetadata(data)
                }
            }
            var result: [String: BookMetadata] = [:]
            result.reserveCapacity(urls.count)
            while let metadata = await group.next() {
                if let m = metadata {
                    result[m.bookId] = m
                }
                if let nextUrl = iter.next() {
                    group.addTask {
                        guard let data = try? Data(contentsOf: nextUrl) else { return nil }
                        return try? Self.decodeMetadata(data)
                    }
                }
            }
            return result
        }
    }

    func bookIdsWithStoredMetadata() -> Set<String> {
        guard let metadataDir = try? Self.metadataDirectoryURL(using: fileManager),
            fileManager.fileExists(atPath: metadataDir.path)
        else {
            return []
        }
        let items =
            (try? fileManager.contentsOfDirectory(
                at: metadataDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        return Set(items.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    func updateLayer(
        bookId: String,
        layer: MetadataLayerType,
        update: @Sendable (inout BookMetadata) -> Void
    ) async throws {
        var metadata: BookMetadata
        if let loaded = try await loadMetadata(bookId: bookId) {
            metadata = loaded
        } else {
            metadata = await MainActor.run {
                BookMetadata(bookId: bookId, file: FileMetadataLayer())
            }
        }

        update(&metadata)

        try await saveMetadata(metadata)
    }

    func updateUserOverrides(bookId: String, overrides: UserOverridesLayer) async throws {
        try await updateLayer(bookId: bookId, layer: .userOverrides) { metadata in
            metadata.userOverrides = overrides
        }
    }

    func updateAppCache(bookId: String, cache: AppCacheMetadataLayer) async throws {
        try await updateLayer(bookId: bookId, layer: .appCache) { metadata in
            metadata.appCache = cache
        }
    }

    func updateAudibleMetadata(bookId: String, audible: AudibleMetadataLayer) async throws {
        try await updateLayer(bookId: bookId, layer: .audible) { metadata in
            metadata.audible = audible
        }
    }

    func updateiTunesMetadata(bookId: String, iTunes: iTunesMetadataLayer) async throws {
        try await updateLayer(bookId: bookId, layer: .iTunes) { metadata in
            metadata.iTunes = iTunes
        }
    }

    func updateGoogleBooksMetadata(bookId: String, google: GoogleBooksMetadataLayer) async throws {
        try await updateLayer(bookId: bookId, layer: .googleBooks) { metadata in
            metadata.googleBooks = google
        }
    }

    func updateFileMetadata(bookId: String, file: FileMetadataLayer) async throws {
        try await updateLayer(bookId: bookId, layer: .file) { metadata in
            metadata.file = file
        }
    }

    func migrateFromBook(_ book: Book) async throws -> BookMetadata {
        if let existing = try await loadMetadata(bookId: book.id) {
            return existing
        }

        let snapshot = await MainActor.run {
            (
                id: book.id,
                title: book.title,
                author: book.author,
                narrator: book.narrator,
                series: book.series,
                seriesNumber: book.seriesNumber,
                year: book.publishedYear,
                publisher: book.publisher,
                genres: book.genres,
                description: book.description,
                duration: book.duration,
                isbn: book.isbn,
                asin: book.asin,
                thumb: book.thumb
            )
        }

        let file = FileMetadataLayer(
            title: nil,
            author: nil,
            narrator: nil,
            series: nil,
            seriesNumber: nil,
            year: nil,
            publisher: nil,
            genres: nil,
            description: nil,
            duration: snapshot.duration,
            isbn: nil,
            asin: nil,
            fileName: nil,
            folderName: nil
        )

        let backend = BackendMetadataLayer(
            title: snapshot.title,
            author: snapshot.author,
            narrator: snapshot.narrator,
            series: snapshot.series,
            seriesNumber: snapshot.seriesNumber,
            year: snapshot.year,
            publisher: snapshot.publisher,
            genres: snapshot.genres,
            description: snapshot.description,
            duration: snapshot.duration,
            isbn: snapshot.isbn,
            asin: snapshot.asin,
            fileName: nil,
            folderName: nil,
            thumb: snapshot.thumb
        )

        let metadata = await MainActor.run {
            BookMetadata(bookId: snapshot.id, file: file, backend: backend)
        }

        try await saveMetadata(metadata)

        AppLogger.network.debug(
            "Migrated book to metadata structure bookId=\(DiagnosticLogSanitizer.identifier(for: snapshot.id))"
        )

        return metadata
    }

    func getAllMetadataFiles() throws -> [URL] {
        let metadataDir = try Self.metadataDirectoryURL(using: fileManager)

        guard fileManager.fileExists(atPath: metadataDir.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(
            at: metadataDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return files.filter { $0.pathExtension == "json" }
    }

    func getMetadataCount() throws -> Int {
        return try getAllMetadataFiles().count
    }

    func clearAllMetadata() throws {
        let metadataDir = try Self.metadataDirectoryURL(using: fileManager)

        if fileManager.fileExists(atPath: metadataDir.path) {
            try fileManager.removeItem(at: metadataDir)
            try Self.createMetadataDirectoryIfNeeded(using: fileManager)
            AppLogger.network.info("Cleared all metadata")
        }
    }

    func calculateDiskUsage() throws -> Int64 {
        let files = try getAllMetadataFiles()
        var totalSize: Int64 = 0

        for fileURL in files {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            if let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
            }
        }

        return totalSize
    }
}
