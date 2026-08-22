import CryptoKit
import Foundation
import Logging

struct SMBBook: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sourceId: String
    let title: String
    let author: String?
    let narrator: String?
    let description: String?
    let series: String?
    let seriesNumber: Int?
    let publishedYear: Int?
    let genres: [String]?
    let publisher: String?
    let isbn: String?
    let asin: String?
    let duration: TimeInterval?

    let folderPath: String

    let audioFiles: [SMBAudioFile]

    let coverPath: String?

    let metadataPath: String?

    let chapters: [SMBChapter]?

    let indexedAt: Date
    var lastScannedAt: Date?

    var totalSize: Int64 {
        audioFiles.reduce(0) { $0 + $1.size }
    }

    var fileCount: Int {
        audioFiles.count
    }

    var isMultiFile: Bool {
        audioFiles.count > 1
    }

    var primaryFile: SMBAudioFile? {
        audioFiles.first
    }

    nonisolated init(
        id: String = UUID().uuidString,
        sourceId: String,
        title: String,
        author: String? = nil,
        narrator: String? = nil,
        description: String? = nil,
        series: String? = nil,
        seriesNumber: Int? = nil,
        publishedYear: Int? = nil,
        genres: [String]? = nil,
        publisher: String? = nil,
        isbn: String? = nil,
        asin: String? = nil,
        duration: TimeInterval? = nil,
        folderPath: String,
        audioFiles: [SMBAudioFile],
        coverPath: String? = nil,
        metadataPath: String? = nil,
        chapters: [SMBChapter]? = nil,
        indexedAt: Date = Date(),
        lastScannedAt: Date? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.title = title
        self.author = author
        self.narrator = narrator
        self.description = description
        self.series = series
        self.seriesNumber = seriesNumber
        self.publishedYear = publishedYear
        self.genres = genres
        self.publisher = publisher
        self.isbn = isbn
        self.asin = asin
        self.duration = duration
        self.folderPath = folderPath
        self.audioFiles = audioFiles
        self.coverPath = coverPath
        self.metadataPath = metadataPath
        self.chapters = chapters
        self.indexedAt = indexedAt
        self.lastScannedAt = lastScannedAt
    }
}

struct SMBAudioFile: Codable, Equatable, Sendable {
    let name: String
    let path: String
    let size: Int64
    let duration: TimeInterval?
    let trackNumber: Int?

    nonisolated init(
        name: String,
        path: String,
        size: Int64,
        duration: TimeInterval? = nil,
        trackNumber: Int? = nil
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.duration = duration
        self.trackNumber = trackNumber
    }
}

struct SMBBookMetadata: Codable, Sendable {
    var title: String?
    var author: String?
    var narrator: String?
    var description: String?
    var series: String?
    var seriesNumber: Int?
    var publishedYear: Int?
    var genres: [String]?
    var publisher: String?
    var isbn: String?
    var asin: String?
    var duration: TimeInterval?
    var language: String?
    var chapters: [SMBChapter]?

    nonisolated init(
        title: String? = nil,
        author: String? = nil,
        narrator: String? = nil,
        description: String? = nil,
        series: String? = nil,
        seriesNumber: Int? = nil,
        publishedYear: Int? = nil,
        genres: [String]? = nil,
        publisher: String? = nil,
        isbn: String? = nil,
        asin: String? = nil,
        duration: TimeInterval? = nil,
        language: String? = nil,
        chapters: [SMBChapter]? = nil
    ) {
        self.title = title
        self.author = author
        self.narrator = narrator
        self.description = description
        self.series = series
        self.seriesNumber = seriesNumber
        self.publishedYear = publishedYear
        self.genres = genres
        self.publisher = publisher
        self.isbn = isbn
        self.asin = asin
        self.duration = duration
        self.language = language
        self.chapters = chapters
    }
}

struct SMBChapter: Codable, Sendable, Equatable {
    let title: String
    let startTime: TimeInterval
    let endTime: TimeInterval?

    func toChapter(index: Int) -> Chapter {
        return Chapter(
            id: "smb_chapter_\(index)",
            start: startTime,
            end: endTime ?? startTime,
            title: title
        )
    }
}

extension SMBBook {
    private static func stableProviderId(for sourceId: String) -> UUID {
        let digest = SHA256.hash(data: Data("enve.smb.\(sourceId)".utf8))
        let bytes = Array(digest)
        let uuidBytes: [UInt8] = Array(bytes.prefix(16))
        return UUID(
            uuid: (
                uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
                uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
                uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
            )
        )
    }

    func toBook() -> Book {
        let stableProvider = Self.stableProviderId(for: sourceId)
        var audioTracks: [AudioTrack]? = nil
        if !audioFiles.isEmpty {
            var cumulativeOffset: TimeInterval = 0
            audioTracks = audioFiles.enumerated().map { index, file in
                let duration = file.duration ?? 0
                let track = AudioTrack(
                    index: index,
                    title: file.name,
                    filePath: file.path,
                    contentUrl: nil,
                    duration: duration,
                    startOffset: cumulativeOffset,
                    fileSize: file.size,
                    format: mimeType(for: file.name),
                    bitrate: nil,
                    sampleRate: nil,
                    channels: nil
                )
                cumulativeOffset += duration
                return track
            }
        }

        let bookChapters: [Chapter]? = chapters?.enumerated().map { index, smbChapter in
            smbChapter.toChapter(index: index + 1)
        }

        let thumbURL: String? = coverPath.flatMap { path in
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path).absoluteString
            } else {
                AppLogger.library.warning(
                    "Cached cover not found pathId=\(DiagnosticLogSanitizer.identifier(for: path))"
                )
                return nil
            }
        }

        return Book(
            id: id,
            ratingKey: id,
            title: title,
            author: author,
            narrator: narrator,
            thumb: thumbURL,
            partKey: primaryFile?.path,
            duration: duration ?? audioTracks?.totalDuration ?? audioFiles.compactMap { $0.duration }.reduce(0, +),
            chapters: bookChapters,
            currentChapterIndex: nil,
            source: .smb,
            backendId: sourceId,
            trackIndex: 0,
            filePath: folderPath,
            audioTracks: audioTracks,
            description: description,
            series: series,
            seriesNumber: seriesNumber,
            publishedYear: publishedYear,
            genres: genres,
            publisher: publisher,
            isbn: isbn,
            asin: asin,
            addedAt: indexedAt,
            libraryName: "SMB Library",
            backendName: sourceId,
            progress: nil,
            lastPlayed: nil,
            providerId: stableProvider,
            libraryId: sourceId
        )
    }

    private func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3": return "audio/mpeg"
        case "m4a", "m4b": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "wav": return "audio/wav"
        default: return "audio/mpeg"
        }
    }
}
