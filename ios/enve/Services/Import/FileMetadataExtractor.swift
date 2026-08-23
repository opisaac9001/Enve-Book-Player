import AVFoundation
import Foundation
import Logging

public actor FileMetadataExtractor {
    public static let shared = FileMetadataExtractor()

    public init() {}

    public func extractMetadata(from fileURL: URL) async throws -> FileMetadataLayer {
        guard fileURL.isFileURL else {
            throw FileMetadataError.invalidURL("URL must be a local file URL")
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FileMetadataError.fileNotFound
        }

        let asset = AVURLAsset(url: fileURL)
        return try await extractMetadata(from: asset)
    }

    public func extractMetadata(from fileURL: URL, timeout: TimeInterval) async throws -> FileMetadataLayer {
        guard fileURL.isFileURL else {
            throw FileMetadataError.invalidURL("URL must be a local file URL")
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FileMetadataError.fileNotFound
        }

        let asset = AVURLAsset(url: fileURL)
        return try await extractMetadata(from: asset, timeout: timeout)
    }

    func extractMetadataFromRemoteStream(streamURL: URL, timeout: TimeInterval = 10.0) async throws -> FileMetadataLayer {
        guard !streamURL.isFileURL else {
            throw FileMetadataError.invalidURL("URL must be a remote stream URL")
        }

        let asset = AVURLAsset(url: streamURL)

        return try await withThrowingTaskGroup(of: FileMetadataLayer.self) { group in
            group.addTask {
                return try await self.extractMetadata(from: asset)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw FileMetadataError.timeout
            }

            guard let result = try await group.next() else {
                throw FileMetadataError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    public func extractMetadataFromRemoteStream(
        streamURL: URL,
        headers: [String: String],
        timeout: TimeInterval = 10.0
    ) async throws -> FileMetadataLayer {
        guard !streamURL.isFileURL else {
            throw FileMetadataError.invalidURL("URL must be a remote stream URL")
        }

        let options = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: streamURL, options: options)

        return try await withThrowingTaskGroup(of: FileMetadataLayer.self) { group in
            group.addTask {
                return try await self.extractMetadata(from: asset)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw FileMetadataError.timeout
            }

            guard let result = try await group.next() else {
                throw FileMetadataError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private func extractMetadata(from asset: AVURLAsset) async throws -> FileMetadataLayer {
        var title: String?
        var author: String?
        var narrator: String?
        var series: String?
        var seriesNumber: Int?
        var year: Int?
        var publisher: String?
        var genres: [String] = []
        var description: String?
        var isbn: String?
        var asin: String?
        var duration: TimeInterval?
        var copyright: String?
        var language: String?
        var encodingTool: String?

        do {
            let durationValue = try await asset.load(.duration)
            duration = CMTimeGetSeconds(durationValue)
        } catch {
            AppLogger.network.error("Could not load duration: \(error.localizedDescription)")
        }

        let commonItems: [AVMetadataItem]
        do {
            commonItems = try await asset.load(.commonMetadata)
        } catch {
            AppLogger.network.error("Could not load common metadata: \(error.localizedDescription)")
            commonItems = []
        }

        for item in commonItems {
            guard let key = item.commonKey?.rawValue else { continue }
            let value: String?
            do { value = try await item.load(.value) as? String } catch { continue }
            guard let value else { continue }
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { continue }

            switch key {
            case AVMetadataKey.commonKeyTitle.rawValue: title = v
            case AVMetadataKey.commonKeyArtist.rawValue: author = v
            case AVMetadataKey.commonKeyAlbumName.rawValue: series = series ?? v
            case AVMetadataKey.commonKeyDescription.rawValue: description = v
            case AVMetadataKey.commonKeyLanguage.rawValue: language = language ?? v
            case AVMetadataKey.commonKeyType.rawValue: narrator = narrator ?? v
            default: break
            }
        }

        let allMetadataItems: [AVMetadataItem]
        do {
            allMetadataItems = try await asset.load(.metadata)
        } catch {
            AppLogger.network.error("Could not load metadata: \(error.localizedDescription)")
            allMetadataItems = []
        }

        for item in allMetadataItems {
            guard let identifier = item.identifier?.rawValue else { continue }

            let value: String?
            do { value = try await item.load(.value) as? String } catch { value = nil }
            let v = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            switch identifier {
            case AVMetadataIdentifier.iTunesMetadataTrackSubTitle.rawValue:
                series = series ?? (v.isEmpty ? nil : v)
            case AVMetadataIdentifier.iTunesMetadataArtist.rawValue:
                author = author ?? (v.isEmpty ? nil : v)
            case AVMetadataIdentifier.iTunesMetadataAlbumArtist.rawValue:
                author = author ?? (v.isEmpty ? nil : v)
            case AVMetadataIdentifier.iTunesMetadataAlbum.rawValue:
                series = series ?? (v.isEmpty ? nil : v)
            case AVMetadataIdentifier.iTunesMetadataComposer.rawValue:
                narrator = narrator ?? (v.isEmpty ? nil : v)
            case AVMetadataIdentifier.iTunesMetadataReleaseDate.rawValue:
                year = year ?? (v.isEmpty ? nil : extractYear(from: v))
            case AVMetadataIdentifier.iTunesMetadataPublisher.rawValue:
                publisher = v.isEmpty ? nil : v
            case AVMetadataIdentifier.iTunesMetadataUserComment.rawValue:
                description = description ?? (v.isEmpty ? nil : v)
            case AVMetadataIdentifier.iTunesMetadataDescription.rawValue:
                description = description ?? (v.isEmpty ? nil : v)
            case "ilst/ldes":
                if !v.isEmpty {
                    if let existing = description { description = v.count > existing.count ? v : existing } else { description = v }
                }
            case AVMetadataIdentifier.iTunesMetadataUserGenre.rawValue:
                if !v.isEmpty, !genres.contains(v) { genres.append(v) }
            case AVMetadataIdentifier.id3MetadataContentType.rawValue:
                if !v.isEmpty, !genres.contains(v) { genres.append(v) }
            case "ilst/cprt":
                copyright = v.isEmpty ? nil : v
            case AVMetadataIdentifier.iTunesMetadataEncodingTool.rawValue:
                encodingTool = v.isEmpty ? nil : v
            case AVMetadataIdentifier.iTunesMetadataDiscNumber.rawValue:
                if seriesNumber == nil, !v.isEmpty {
                    let numPart = v.components(separatedBy: "/").first ?? v
                    seriesNumber = Int(numPart.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            default:
                if identifier.lowercased().contains("genre") {
                    if !v.isEmpty, !genres.contains(v) { genres.append(v) }
                } else if identifier.lowercased().contains("lang") {
                    language = language ?? (v.isEmpty ? nil : v)
                }
            }
        }

        if asin == nil { asin = try? await extractASIN(from: asset) }
        if isbn == nil { isbn = try? await extractISBN(from: asset) }
        if seriesNumber == nil { seriesNumber = try? await extractSeriesNumber(from: asset) }

        return FileMetadataLayer(
            title: title,
            author: author,
            narrator: narrator,
            series: series,
            seriesNumber: seriesNumber,
            year: year,
            publisher: publisher,
            genres: genres.isEmpty ? nil : genres,
            description: description,
            duration: duration,
            isbn: isbn,
            asin: asin,
            fileName: nil,
            folderName: nil,
            coverPath: nil,
            copyright: copyright,
            language: language,
            encodingTool: encodingTool
        )
    }

    func extractAndSaveCoverImage(from filePath: String) async throws -> String? {
        let fileURL = URL(fileURLWithPath: filePath)
        let asset = AVURLAsset(url: fileURL)

        let commonItems: [AVMetadataItem]
        do { commonItems = try await asset.load(.commonMetadata) } catch { commonItems = [] }

        for item in commonItems {
            guard item.commonKey == .commonKeyArtwork else { continue }
            if let imageData = try? await item.load(.value) as? Data, !imageData.isEmpty {
                return try? saveImageData(imageData, nextTo: fileURL)
            }
        }

        let allItems: [AVMetadataItem]
        do { allItems = try await asset.load(.metadata) } catch { allItems = [] }

        for item in allItems {
            let isArtwork: Bool
            if let id = item.identifier {
                isArtwork = (id.rawValue == "ilst/covr" || id == .commonIdentifierArtwork)
            } else if let key = item.commonKey {
                isArtwork = (key == .commonKeyArtwork)
            } else {
                let rawKey = item.key as? String ?? ""
                isArtwork = rawKey == "covr" || rawKey.hasSuffix("/covr")
            }
            guard isArtwork else { continue }
            if let imageData = try? await item.load(.value) as? Data, !imageData.isEmpty {
                return try? saveImageData(imageData, nextTo: fileURL)
            }
        }

        return nil
    }

    private func saveImageData(_ data: Data, nextTo audioURL: URL) throws -> String? {
        let directory = audioURL.deletingLastPathComponent()
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        let ext: String
        if data.count >= 8, data[0] == 0x89, data[1] == 0x50 {
            ext = "png"
        } else if data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 {
            ext = "jpg"
        } else {
            ext = "jpg"
        }
        let coverURL = directory.appendingPathComponent("\(baseName).cover.\(ext)")
        try data.write(to: coverURL, options: [.atomic])
        AppLogger.network.debug(
            "Extracted cover image \(DiagnosticLogSanitizer.fileDescriptor(for: coverURL))"
        )
        return coverURL.path
    }

    private func extractASIN(from asset: AVURLAsset) async throws -> String? {
        let allMetadataItems: [AVMetadataItem]
        do {
            allMetadataItems = try await asset.load(.metadata)
        } catch {
            return nil
        }

        for item in allMetadataItems {
            guard let identifier = item.identifier?.rawValue else {
                continue
            }

            let value: String?
            do {
                value = try await item.load(.value) as? String
            } catch {
                continue
            }

            guard let value = value else {
                continue
            }

            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if trimmed.count == 10 && trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return trimmed
            }

            let lowerIdentifier = identifier.lowercased()
            if lowerIdentifier.contains("asin") || lowerIdentifier.contains("audible") {
                let asinPattern = #"B[0-9A-Z]{9}"#
                if let range = value.range(of: asinPattern, options: .regularExpression) {
                    return String(value[range]).uppercased()
                }
            }
        }

        return nil
    }

    private func extractISBN(from asset: AVURLAsset) async throws -> String? {
        let allMetadataItems: [AVMetadataItem]
        do {
            allMetadataItems = try await asset.load(.metadata)
        } catch {
            return nil
        }

        for item in allMetadataItems {
            guard let identifier = item.identifier?.rawValue else {
                continue
            }

            let value: String?
            do {
                value = try await item.load(.value) as? String
            } catch {
                continue
            }

            guard let value = value else {
                continue
            }

            let lowerIdentifier = identifier.lowercased()
            if lowerIdentifier.contains("isbn") {
                let cleaned = value.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
                if cleaned.count == 10 || cleaned.count == 13, cleaned.allSatisfy({ $0.isNumber }) {
                    return cleaned
                }
            }
        }

        return nil
    }

    private func extractSeriesNumber(from asset: AVURLAsset) async throws -> Int? {
        let allMetadataItems: [AVMetadataItem]
        do {
            allMetadataItems = try await asset.load(.metadata)
        } catch {
            return nil
        }

        for item in allMetadataItems {
            guard let identifier = item.identifier?.rawValue else {
                continue
            }

            let value: String?
            do {
                value = try await item.load(.value) as? String
            } catch {
                continue
            }

            guard let value = value else {
                continue
            }

            if identifier == AVMetadataIdentifier.iTunesMetadataTrackNumber.rawValue {
                let numberPart = value.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let number = numberPart, let intValue = Int(number) {
                    return intValue
                }
            }
        }

        return nil
    }

    private func extractYear(from dateString: String) -> Int? {
        let formatters: [DateFormatter] = [
            {
                let f = DateFormatter(); f.dateFormat = "yyyy"; return f
            }(),
            {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
            }(),
            {
                let f = DateFormatter(); f.dateFormat = "MM/dd/yyyy"; return f
            }(),
            {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f
            }(),
        ]

        for formatter in formatters {
            if let date = formatter.date(from: dateString) {
                let calendar = Calendar.current
                return calendar.component(.year, from: date)
            }
        }

        let yearPattern = #"\b(19|20)\d{2}\b"#
        if let range = dateString.range(of: yearPattern, options: .regularExpression) {
            if let year = Int(String(dateString[range])) {
                return year
            }
        }

        return nil
    }

    private func extractMetadata(from asset: AVURLAsset, timeout: TimeInterval) async throws -> FileMetadataLayer {
        try await withThrowingTaskGroup(of: FileMetadataLayer.self) { group in
            group.addTask {
                try await self.extractMetadata(from: asset)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw FileMetadataError.timeout
            }

            guard let result = try await group.next() else {
                throw FileMetadataError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}

enum FileMetadataError: LocalizedError {
    case invalidURL(String)
    case fileNotFound
    case timeout
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let message):
            return "Invalid URL: \(message)"
        case .fileNotFound:
            return "File not found"
        case .timeout:
            return "Metadata extraction timed out"
        case .loadFailed(let message):
            return "Failed to load metadata: \(message)"
        }
    }
}

extension FileMetadataExtractor {
    nonisolated func extractMetadata(from filePath: String) async throws -> LocalBookMetadata {
        try await extractMetadata(from: filePath, metadataTimeout: nil)
    }

    nonisolated func extractMetadata(from filePath: String, timeout: TimeInterval) async throws -> LocalBookMetadata {
        try await extractMetadata(from: filePath, metadataTimeout: timeout)
    }

    private nonisolated func extractMetadata(from filePath: String, metadataTimeout: TimeInterval?) async throws -> LocalBookMetadata {
        let fileURL = URL(fileURLWithPath: filePath)
        let extractor = FileMetadataExtractor()
        let fileMetadata: FileMetadataLayer
        if let metadataTimeout {
            fileMetadata = try await extractor.extractMetadata(from: fileURL, timeout: metadataTimeout)
        } else {
            fileMetadata = try await extractor.extractMetadata(from: fileURL)
        }

        let coverPath = try? await extractor.extractAndSaveCoverImage(from: filePath)

        return LocalBookMetadata(
            title: fileMetadata.title ?? fileURL.deletingPathExtension().lastPathComponent,
            author: fileMetadata.author,
            narrator: fileMetadata.narrator,
            description: fileMetadata.description,
            series: fileMetadata.series,
            seriesNumber: fileMetadata.seriesNumber,
            publishedYear: fileMetadata.year,
            genres: fileMetadata.genres?.isEmpty == false ? fileMetadata.genres : nil,
            publisher: fileMetadata.publisher,
            isbn: fileMetadata.isbn,
            asin: fileMetadata.asin,
            duration: fileMetadata.duration,
            chapters: nil,
            coverImagePath: coverPath,
            copyright: fileMetadata.copyright,
            language: fileMetadata.language,
            encodingTool: fileMetadata.encodingTool
        )
    }
}
