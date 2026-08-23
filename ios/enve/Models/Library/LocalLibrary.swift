import CryptoKit
@preconcurrency import Foundation

struct LocalLibrary: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let folderPath: String
    let createdAt: Date
    var lastScanned: Date?
    let isEnabled: Bool
    let type: LibraryType
    let bookmarkData: Data?

    enum LibraryType: String, Codable, Sendable {
        case local
        case fileSharing
        case network
        case webdav
    }

    nonisolated init(
        id: String = UUID().uuidString,
        name: String,
        folderPath: String,
        createdAt: Date = Date(),
        lastScanned: Date? = nil,
        isEnabled: Bool = true,
        type: LibraryType = .local,
        bookmarkData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.createdAt = createdAt
        self.lastScanned = lastScanned
        self.isEnabled = isEnabled
        self.type = type
        self.bookmarkData = bookmarkData
    }

    var isRemote: Bool {
        type == .network || type == .webdav
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case folderPath
        case createdAt
        case lastScanned
        case isEnabled
        case type
        case bookmarkData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        folderPath = try container.decode(String.self, forKey: .folderPath)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastScanned = try container.decodeIfPresent(Date.self, forKey: .lastScanned)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        type = try container.decodeIfPresent(LibraryType.self, forKey: .type) ?? .local
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(folderPath, forKey: .folderPath)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastScanned, forKey: .lastScanned)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
    }
}

struct LocalBookMetadata: Sendable {
    var title: String
    var author: String?
    var narrator: String?
    var description: String?
    var series: String?
    var seriesNumber: Int?
    var seriesSequence: String?
    var publishedYear: Int?
    var genres: [String]?
    var publisher: String?
    var isbn: String?
    var asin: String?
    var duration: TimeInterval?
    var chapters: [LocalChapter]?
    var coverImagePath: String?
    var lastUpdated: Date
    var metadataVersion: String
    var copyright: String?
    var language: String?
    var encodingTool: String?
    var epub3Features: EPUB3Features?

    nonisolated init(
        title: String,
        author: String? = nil,
        narrator: String? = nil,
        description: String? = nil,
        series: String? = nil,
        seriesNumber: Int? = nil,
        seriesSequence: String? = nil,
        publishedYear: Int? = nil,
        genres: [String]? = nil,
        publisher: String? = nil,
        isbn: String? = nil,
        asin: String? = nil,
        duration: TimeInterval? = nil,
        chapters: [LocalChapter]? = nil,
        coverImagePath: String? = nil,
        lastUpdated: Date = Date(),
        metadataVersion: String = "1.0",
        copyright: String? = nil,
        language: String? = nil,
        encodingTool: String? = nil,
        epub3Features: EPUB3Features? = nil
    ) {
        self.title = title
        self.author = author
        self.narrator = narrator
        self.description = description
        self.series = series
        self.seriesNumber = seriesNumber
        self.seriesSequence = seriesSequence
        self.publishedYear = publishedYear
        self.genres = genres
        self.publisher = publisher
        self.isbn = isbn
        self.asin = asin
        self.duration = duration
        self.chapters = chapters
        self.coverImagePath = coverImagePath
        self.lastUpdated = lastUpdated
        self.metadataVersion = metadataVersion
        self.copyright = copyright
        self.language = language
        self.encodingTool = encodingTool
        self.epub3Features = epub3Features
    }
}

extension LocalBookMetadata: Equatable {
    nonisolated static func == (lhs: LocalBookMetadata, rhs: LocalBookMetadata) -> Bool {
        guard lhs.title == rhs.title else { return false }
        guard lhs.author == rhs.author else { return false }
        guard lhs.narrator == rhs.narrator else { return false }
        guard lhs.description == rhs.description else { return false }
        guard lhs.series == rhs.series else { return false }
        guard lhs.seriesNumber == rhs.seriesNumber else { return false }
        guard lhs.seriesSequence == rhs.seriesSequence else { return false }
        guard lhs.publishedYear == rhs.publishedYear else { return false }
        guard lhs.genres == rhs.genres else { return false }
        guard lhs.publisher == rhs.publisher else { return false }
        guard lhs.isbn == rhs.isbn else { return false }
        guard lhs.asin == rhs.asin else { return false }
        guard lhs.duration == rhs.duration else { return false }
        guard lhs.chapters == rhs.chapters else { return false }
        guard lhs.coverImagePath == rhs.coverImagePath else { return false }
        guard lhs.lastUpdated == rhs.lastUpdated else { return false }
        guard lhs.metadataVersion == rhs.metadataVersion else { return false }
        guard lhs.copyright == rhs.copyright else { return false }
        guard lhs.language == rhs.language else { return false }
        guard lhs.encodingTool == rhs.encodingTool else { return false }
        guard lhs.epub3Features == rhs.epub3Features else { return false }
        return true
    }
}

extension LocalBookMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case title, author, narrator, description, series, seriesNumber, seriesSequence
        case publishedYear, genres, publisher, isbn, asin, duration
        case chapters, coverImagePath, lastUpdated, metadataVersion
        case copyright, language, encodingTool, epub3Features
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decode(String.self, forKey: .title)
        self.author = try container.decodeIfPresent(String.self, forKey: .author)
        self.narrator = try container.decodeIfPresent(String.self, forKey: .narrator)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.series = try container.decodeIfPresent(String.self, forKey: .series)
        self.seriesNumber = try container.decodeIfPresent(Int.self, forKey: .seriesNumber)
        self.seriesSequence = try container.decodeIfPresent(String.self, forKey: .seriesSequence)
        self.publishedYear = try container.decodeIfPresent(Int.self, forKey: .publishedYear)
        self.genres = try container.decodeIfPresent([String].self, forKey: .genres)
        self.publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
        self.isbn = try container.decodeIfPresent(String.self, forKey: .isbn)
        self.asin = try container.decodeIfPresent(String.self, forKey: .asin)
        self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        self.chapters = try container.decodeIfPresent([LocalChapter].self, forKey: .chapters)
        self.coverImagePath = try container.decodeIfPresent(String.self, forKey: .coverImagePath)
        self.lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        self.metadataVersion = try container.decode(String.self, forKey: .metadataVersion)
        self.copyright = try container.decodeIfPresent(String.self, forKey: .copyright)
        self.language = try container.decodeIfPresent(String.self, forKey: .language)
        self.encodingTool = try container.decodeIfPresent(String.self, forKey: .encodingTool)
        self.epub3Features = try container.decodeIfPresent(EPUB3Features.self, forKey: .epub3Features)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(narrator, forKey: .narrator)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(series, forKey: .series)
        try container.encodeIfPresent(seriesNumber, forKey: .seriesNumber)
        try container.encodeIfPresent(seriesSequence, forKey: .seriesSequence)
        try container.encodeIfPresent(publishedYear, forKey: .publishedYear)
        try container.encodeIfPresent(genres, forKey: .genres)
        try container.encodeIfPresent(publisher, forKey: .publisher)
        try container.encodeIfPresent(isbn, forKey: .isbn)
        try container.encodeIfPresent(asin, forKey: .asin)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(chapters, forKey: .chapters)
        try container.encodeIfPresent(coverImagePath, forKey: .coverImagePath)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(metadataVersion, forKey: .metadataVersion)
        try container.encodeIfPresent(copyright, forKey: .copyright)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(encodingTool, forKey: .encodingTool)
        try container.encodeIfPresent(epub3Features, forKey: .epub3Features)
    }
}

struct LocalChapter: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let duration: TimeInterval

    nonisolated init(
        id: String = UUID().uuidString,
        title: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        duration: TimeInterval
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
    }
}

struct LocalBookSidecar: Sendable {
    let metadata: LocalBookMetadata
    let fileHash: String
    let fileName: String
    let format: String

    nonisolated init(
        metadata: LocalBookMetadata,
        fileHash: String,
        fileName: String,
        format: String
    ) {
        self.metadata = metadata
        self.fileHash = fileHash
        self.fileName = fileName
        self.format = format
    }
}

extension LocalBookSidecar: Codable {
    private enum CodingKeys: String, CodingKey {
        case metadata, fileHash, fileName, format
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.metadata = try container.decode(LocalBookMetadata.self, forKey: .metadata)
        self.fileHash = try container.decode(String.self, forKey: .fileHash)
        self.fileName = try container.decode(String.self, forKey: .fileName)
        self.format = try container.decode(String.self, forKey: .format)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(fileHash, forKey: .fileHash)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(format, forKey: .format)
    }
}

enum AudiobookFormat: String, CaseIterable {
    case m4b = "m4b"
    case m4a = "m4a"
    case mp4 = "mp4"
    case aac = "aac"

    case mp3 = "mp3"

    case flac = "flac"
    case alac = "alac"
    case wav = "wav"
    case aiff = "aiff"
    case aif = "aif"

    case ogg = "ogg"
    case oga = "oga"
    case opus = "opus"

    case caf = "caf"
    case aifc = "aifc"

    case wma = "wma"

    case spx = "spx"

    var isSupported: Bool {
        return true
    }

    var mimeType: String {
        switch self {
        case .m4b, .m4a, .mp4: return "audio/mp4"
        case .aac: return "audio/aac"
        case .mp3: return "audio/mpeg"
        case .flac: return "audio/flac"
        case .alac: return "audio/mp4"
        case .wav: return "audio/wav"
        case .aiff, .aif, .aifc: return "audio/aiff"
        case .ogg, .oga: return "audio/ogg"
        case .opus: return "audio/opus"
        case .caf: return "audio/x-caf"
        case .wma: return "audio/x-ms-wma"
        case .spx: return "audio/x-speex"
        }
    }

    var isNativelySupported: Bool {
        switch self {
        case .m4b, .m4a, .mp4, .aac, .mp3, .flac, .alac, .wav, .aiff, .aif, .aifc, .caf, .opus:
            return true
        case .ogg, .oga:
            if #available(iOS 17.0, *) {
                return true
            }
            return false
        case .wma, .spx:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .m4b: return "M4B (Audiobook)"
        case .m4a: return "M4A (AAC)"
        case .mp4: return "MP4"
        case .aac: return "AAC"
        case .mp3: return "MP3"
        case .flac: return "FLAC (Lossless)"
        case .alac: return "ALAC (Apple Lossless)"
        case .wav: return "WAV (Uncompressed)"
        case .aiff, .aif: return "AIFF"
        case .aifc: return "AIFF-C"
        case .ogg, .oga: return "Ogg Vorbis"
        case .opus: return "Opus"
        case .caf: return "Core Audio Format"
        case .wma: return "Windows Media Audio"
        case .spx: return "Speex"
        }
    }

    nonisolated static func from(fileExtension: String) -> AudiobookFormat? {
        return AudiobookFormat(rawValue: fileExtension.lowercased())
    }

    static func streamingMimeType(forFileExtension fileExtension: String?) -> String {
        let normalized = (fileExtension ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return from(fileExtension: normalized)?.mimeType ?? "audio/mpeg"
    }

    static var allExtensions: [String] {
        return allCases.map { $0.rawValue }
    }

    static var nativelySupportedExtensions: [String] {
        return allCases.filter { $0.isNativelySupported }.map { $0.rawValue }
    }
}

enum EbookFormat: String, CaseIterable {
    case epub = "epub"
    case pdf = "pdf"
    case cbz = "cbz"
    case cbr = "cbr"
    case fb2 = "fb2"
    case mobi = "mobi"
    case azw3 = "azw3"
    case azw = "azw"
    case imagefolder = "imagefolder"

    nonisolated static let imagePageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "bmp", "gif", "avif"]

    nonisolated static let mobiExtensions: Set<String> = ["mobi", "azw3", "azw"]

    var mimeType: String {
        switch self {
        case .epub: return "application/epub+zip"
        case .pdf: return "application/pdf"
        case .cbz: return "application/vnd.comicbook+zip"
        case .cbr: return "application/vnd.comicbook-rar"
        case .fb2: return "application/x-fictionbook+xml"
        case .mobi: return "application/x-mobipocket-ebook"
        case .azw3: return "application/x-mobi8-ebook"
        case .azw: return "application/x-mobipocket-ebook"
        case .imagefolder: return "application/x-image-folder"
        }
    }

    var displayName: String {
        switch self {
        case .epub: return "EPUB"
        case .pdf: return "PDF"
        case .cbz: return "Comic Book (ZIP)"
        case .cbr: return "Comic Book (RAR)"
        case .fb2: return "FictionBook"
        case .mobi: return "MOBI"
        case .azw3: return "AZW3 (Kindle)"
        case .azw: return "AZW (Kindle)"
        case .imagefolder: return "Image Book"
        }
    }

    var isReadiumSupported: Bool {
        switch self {
        case .epub, .pdf: return true
        case .cbz, .cbr, .fb2, .imagefolder, .mobi, .azw3, .azw: return false
        }
    }

    var requiresMobiConversion: Bool {
        switch self {
        case .mobi, .azw3, .azw: return true
        default: return false
        }
    }

    nonisolated static func from(fileExtension: String) -> EbookFormat? {
        return EbookFormat(rawValue: fileExtension.lowercased())
    }

    nonisolated static func isImagePageExtension(_ ext: String) -> Bool {
        imagePageExtensions.contains(ext.lowercased())
    }

    nonisolated static func from(downloadMimeType mimeType: String) -> EbookFormat? {
        switch mimeType.lowercased() {
        case "application/epub+zip": return .epub
        case "application/pdf": return .pdf
        case "application/x-cbz", "application/vnd.comicbook+zip", "application/zip", "application/x-zip-compressed": return .cbz
        case "application/x-cbr", "application/vnd.comicbook-rar", "application/x-rar-compressed", "application/vnd.rar": return .cbr
        case "application/x-fictionbook+xml", "application/fb2+xml": return .fb2
        default: return nil
        }
    }

    static func detectedExtension(inDownloadResponse response: HTTPURLResponse) -> String? {
        if let mimeType = response.mimeType, let format = from(downloadMimeType: mimeType) {
            return format.rawValue
        }

        if let suggested = response.suggestedFilename {
            let suggestedExtension = (suggested as NSString).pathExtension.lowercased()
            if allExtensions.contains(suggestedExtension) {
                return suggestedExtension
            }
        }

        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() {
            return allExtensions.first { disposition.contains(".\($0)") }
        }

        return nil
    }

    static var allExtensions: [String] {
        return allCases.map { $0.rawValue }
    }
}

struct LocalLibraryScanResult: Equatable {
    let localLibraryId: String
    let booksFound: [LocalBookFile]
    let skippedFiles: [String]
    let scanDuration: TimeInterval
    let scannedAt: Date

    var totalBooks: Int { booksFound.count }
    var totalSkipped: Int { skippedFiles.count }
}

struct LocalBookFile: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let fileName: String
    let filePath: String
    let relativePath: String?
    let fileSize: Int64
    let format: String
    let fileHash: String?
    var metadata: LocalBookMetadata?
    var sidecarPath: String?
    let extractedAt: Date

    let audioFiles: [AudioFileInfo]?

    nonisolated init(
        id: String = UUID().uuidString,
        fileName: String,
        filePath: String,
        relativePath: String? = nil,
        fileSize: Int64,
        format: String,
        fileHash: String? = nil,
        metadata: LocalBookMetadata? = nil,
        sidecarPath: String? = nil,
        extractedAt: Date = Date(),
        audioFiles: [AudioFileInfo]? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.filePath = filePath
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.format = format
        self.fileHash = fileHash
        self.metadata = metadata
        self.sidecarPath = sidecarPath
        self.extractedAt = extractedAt
        self.audioFiles = audioFiles
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case fileName
        case filePath
        case relativePath
        case fileSize
        case format
        case fileHash
        case metadata
        case sidecarPath
        case extractedAt
        case audioFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        fileName = try container.decode(String.self, forKey: .fileName)
        filePath = try container.decode(String.self, forKey: .filePath)
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? (URL(fileURLWithPath: fileName).pathExtension.lowercased())
        fileHash = try container.decodeIfPresent(String.self, forKey: .fileHash)
        metadata = try container.decodeIfPresent(LocalBookMetadata.self, forKey: .metadata)
        sidecarPath = try container.decodeIfPresent(String.self, forKey: .sidecarPath)
        extractedAt = try container.decodeIfPresent(Date.self, forKey: .extractedAt) ?? Date()
        audioFiles = try container.decodeIfPresent([AudioFileInfo].self, forKey: .audioFiles)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(filePath, forKey: .filePath)
        try container.encodeIfPresent(relativePath, forKey: .relativePath)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encode(format, forKey: .format)
        try container.encodeIfPresent(fileHash, forKey: .fileHash)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(sidecarPath, forKey: .sidecarPath)
        try container.encode(extractedAt, forKey: .extractedAt)
        try container.encodeIfPresent(audioFiles, forKey: .audioFiles)
    }

    nonisolated static func sidecarPath(for filePath: String) -> String {
        let url = URL(fileURLWithPath: filePath)
        let fileName = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent().path
        return (directory as NSString).appendingPathComponent("\(fileName).sidecar.json")
    }

    nonisolated var displayTitle: String {
        return metadata?.title ?? fileName.replacingOccurrences(of: ".\(format)", with: "")
    }

    nonisolated var displayAuthor: String? {
        return metadata?.author
    }

    var isMultiFile: Bool {
        guard let files = audioFiles else { return false }
        return files.count > 1
    }

    var fileCount: Int {
        return audioFiles?.count ?? 1
    }

    var totalDuration: TimeInterval? {
        if let files = audioFiles {
            let total = files.compactMap { $0.duration }.reduce(0, +)
            return total > 0 ? total : metadata?.duration
        }
        return metadata?.duration
    }

    nonisolated func toAudioTracks() -> [AudioTrack]? {
        guard let files = audioFiles, !files.isEmpty else {
            guard let duration = metadata?.duration else { return nil }
            return [
                AudioTrack(
                    id: id,
                    index: 0,
                    title: displayTitle,
                    filePath: filePath,
                    contentUrl: nil,
                    duration: duration,
                    startOffset: 0,
                    fileSize: fileSize,
                    format: format
                )
            ]
        }

        var tracks: [AudioTrack] = []
        var cumulativeOffset: TimeInterval = 0

        for (index, file) in files.enumerated() {
            let track = AudioTrack(
                id: file.id,
                index: index,
                title: file.title ?? file.fileName,
                filePath: file.filePath,
                contentUrl: nil,
                duration: file.duration ?? 0,
                startOffset: cumulativeOffset,
                fileSize: file.fileSize,
                format: file.format
            )
            tracks.append(track)
            cumulativeOffset += file.duration ?? 0
        }

        return tracks
    }
}

struct AudioFileInfo: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let fileName: String
    let filePath: String
    let fileSize: Int64
    let format: String
    let duration: TimeInterval?
    let trackNumber: Int?
    let title: String?

    nonisolated init(
        id: String = UUID().uuidString,
        fileName: String,
        filePath: String,
        fileSize: Int64,
        format: String,
        duration: TimeInterval? = nil,
        trackNumber: Int? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.filePath = filePath
        self.fileSize = fileSize
        self.format = format
        self.duration = duration
        self.trackNumber = trackNumber
        self.title = title
    }
}

extension LocalBookFile {
    private static func stableProviderId(for libraryId: String) -> UUID {
        let digest = SHA256.hash(data: Data("enve.local.\(libraryId)".utf8))

        let bytes: [UInt8] = digest.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: UInt8.self))
        }

        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        if bytes.count >= 16 {
            uuid.0 = bytes[0]
            uuid.1 = bytes[1]
            uuid.2 = bytes[2]
            uuid.3 = bytes[3]
            uuid.4 = bytes[4]
            uuid.5 = bytes[5]
            uuid.6 = bytes[6]
            uuid.7 = bytes[7]
            uuid.8 = bytes[8]
            uuid.9 = bytes[9]
            uuid.10 = bytes[10]
            uuid.11 = bytes[11]
            uuid.12 = bytes[12]
            uuid.13 = bytes[13]
            uuid.14 = bytes[14]
            uuid.15 = bytes[15]
        }

        return UUID(uuid: uuid)
    }

    func toBook(libraryId: String) -> Book {
        let providerId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        let detectedMediaType: AppMediaType = EbookFormat.from(fileExtension: format) != nil ? .ebook : .audiobook

        let title = self.metadata?.title ?? self.fileName
        let author = self.metadata?.author
        let narrator = self.metadata?.narrator
        let thumb = self.metadata?.coverImagePath
        let tracks = self.toAudioTracks()
        let trackDuration = tracks?.reduce(0) { $0 + $1.duration } ?? 0

        let chapters: [Chapter] =
            self.metadata?.chapters?.enumerated().map { index, chapter in
                Chapter(
                    id: "local_chapter_\(index)",
                    start: chapter.startTime,
                    end: chapter.endTime,
                    title: chapter.title
                )
            } ?? []

        let chapterDuration = chapters.last?.end ?? 0
        let metadataDuration = self.metadata?.duration ?? 0
        let duration: TimeInterval = max(metadataDuration, trackDuration, chapterDuration)

        let description = self.metadata?.description
        let series = self.metadata?.series
        let seriesNumber = self.metadata?.seriesNumber
        let publishedYear = self.metadata?.publishedYear
        let genres = self.metadata?.genres
        let publisher = self.metadata?.publisher
        let isbn = self.metadata?.isbn
        let asin = self.metadata?.asin
        let copyright = self.metadata?.copyright
        let language = self.metadata?.language
        let encodingTool = self.metadata?.encodingTool

        let ebookFileURL = detectedMediaType == .ebook ? URL(fileURLWithPath: self.filePath) : nil
        let epub3Features = self.metadata?.epub3Features

        return Book(
            id: self.id,
            title: title,
            author: author,
            narrator: narrator,
            thumb: thumb,
            duration: duration,
            chapters: chapters,
            source: .local,
            backendId: libraryId,
            filePath: self.filePath,
            audioTracks: tracks,
            mediaType: detectedMediaType,
            ebookFileURL: ebookFileURL,
            epub3Features: epub3Features,
            description: description,
            series: series,
            seriesNumber: seriesNumber,
            publishedYear: publishedYear,
            genres: genres,
            publisher: publisher,
            isbn: isbn,
            asin: asin,
            addedAt: self.extractedAt,
            libraryName: libraryId,
            backendName: "local",
            copyright: copyright,
            language: language,
            encodingTool: encodingTool,
            providerId: providerId,
            libraryId: libraryId
        )
    }
}
