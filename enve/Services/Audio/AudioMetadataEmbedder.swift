@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Logging

struct NonSendableBox<T>: @unchecked Sendable {
    nonisolated(unsafe) let value: T

    @inline(never)
    init(_ v: T) {
        self.value = v
    }
}

enum AudioMetadataEmbeddingError: LocalizedError {
    case unsupportedFormat(String)
    case fileNotWritable
    case missingAudioTrack
    case exportFailed(String)
    case id3WriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported format for embedding: .\(ext)"
        case .fileNotWritable:
            return "File is not writable"
        case .missingAudioTrack:
            return "Missing audio track"
        case .exportFailed(let message):
            return "Failed to write updated file: \(message)"
        case .id3WriteFailed(let message):
            return "Failed to write ID3 metadata: \(message)"
        }
    }
}

struct AudioMetadataEmbedder: Sendable {
    private let fileManager = FileManager.default

    nonisolated init() {}

    func embed(metadata: LocalBookMetadata, intoAudioFileAtPath filePath: String) async throws {
        let url = URL(fileURLWithPath: filePath)
        let ext = url.pathExtension.lowercased()

        guard fileManager.isWritableFile(atPath: filePath) else {
            throw AudioMetadataEmbeddingError.fileNotWritable
        }

        let coverData = try loadCoverData(from: metadata.coverImagePath, relativeTo: url)
        let chapterCount = metadata.chapters?.count ?? 0
        AppLogger.general.debug("Embed start: ext=\(ext) cover=\(coverData != nil) chapters=\(chapterCount)")

        switch ext {
        case "mp3":
            try embedID3v24(metadata: metadata, coverData: coverData, intoMP3At: url)
        case "m4b", "m4a":
            try await embedMP4(metadata: metadata, coverData: coverData, intoMP4At: url)
        default:
            throw AudioMetadataEmbeddingError.unsupportedFormat(ext)
        }
    }

    private func loadCoverData(from coverImagePath: String?, relativeTo audioURL: URL) throws -> Data? {
        guard let coverImagePath, !coverImagePath.isEmpty else { return nil }

        let coverURL: URL
        if coverImagePath.hasPrefix("/") {
            coverURL = URL(fileURLWithPath: coverImagePath)
        } else {
            coverURL = audioURL.deletingLastPathComponent().appendingPathComponent(coverImagePath)
        }

        guard fileManager.fileExists(atPath: coverURL.path) else { return nil }
        return try Data(contentsOf: coverURL)
    }

    private func embedID3v24(metadata: LocalBookMetadata, coverData: Data?, intoMP3At url: URL) throws {
        let input = try Data(contentsOf: url)

        let (audioStartOffset, _) = ID3v2.detectExistingTag(in: input)
        let audioBytes = input.subdata(in: audioStartOffset..<input.count)

        let tag = ID3v2.buildTagV24(
            title: metadata.title,
            author: metadata.author,
            narrator: metadata.narrator,
            series: metadata.series,
            seriesNumber: metadata.seriesNumber,
            publishedYear: metadata.publishedYear,
            genres: metadata.genres,
            description: metadata.description,
            publisher: metadata.publisher,
            isbn: metadata.isbn,
            asin: metadata.asin,
            coverData: coverData,
            chapters: metadata.chapters
        )

        let tempURL = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
        var out = Data()
        out.append(tag)
        out.append(audioBytes)

        do {
            try out.write(to: tempURL, options: [.atomic])
            _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw AudioMetadataEmbeddingError.id3WriteFailed(error.localizedDescription)
        }
    }

    @MainActor
    private func embedMP4(metadata: LocalBookMetadata, coverData: Data?, intoMP4At url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw AudioMetadataEmbeddingError.missingAudioTrack
        }

        let outputURL = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        let fileType: AVFileType = .m4a

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)

        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(audioOutput) else {
            throw AudioMetadataEmbeddingError.exportFailed("Cannot add audio output")
        }
        reader.add(audioOutput)

        let fds: [CMFormatDescription] = try await audioTrack.load(.formatDescriptions)
        guard let sourceFormat = fds.first else {
            throw AudioMetadataEmbeddingError.exportFailed("Missing source format description")
        }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: sourceFormat)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw AudioMetadataEmbeddingError.exportFailed("Cannot add audio input")
        }
        writer.add(audioInput)

        writer.metadata = buildMP4MetadataItems(metadata: metadata, coverData: coverData)

        var chapterAdaptor: AVAssetWriterInputMetadataAdaptor?
        if let chapters = metadata.chapters, !chapters.isEmpty {
            if let adaptor = try? makeChapterMetadataAdaptor(writer: writer) {
                chapterAdaptor = adaptor
            }
        }

        guard writer.startWriting() else {
            throw AudioMetadataEmbeddingError.exportFailed(writer.error?.localizedDescription ?? "Writer failed")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw AudioMetadataEmbeddingError.exportFailed(reader.error?.localizedDescription ?? "Reader failed")
        }

        if let adaptor = chapterAdaptor, let chapters = metadata.chapters {
            try appendChapters(chapters, adaptor: adaptor, totalDuration: try await asset.load(.duration))
        }

        let readerBox = NonSendableBox(reader)
        let writerBox = NonSendableBox(writer)
        let inputBox = NonSendableBox(audioInput)
        let outputBox = NonSendableBox(audioOutput)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let writingQueue = DispatchQueue(label: "AudioMetadataEmbedder.write")

            inputBox.value.requestMediaDataWhenReady(on: writingQueue) {
                while inputBox.value.isReadyForMoreMediaData {
                    if let sample = outputBox.value.copyNextSampleBuffer() {
                        if !inputBox.value.append(sample) {
                            readerBox.value.cancelReading()
                            writerBox.value.cancelWriting()
                            continuation.resume(
                                throwing: AudioMetadataEmbeddingError.exportFailed(
                                    writerBox.value.error?.localizedDescription ?? "Failed appending audio"
                                )
                            )
                            return
                        }
                    } else {
                        inputBox.value.markAsFinished()
                        writerBox.value.finishWriting {
                            if writerBox.value.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(
                                    throwing: AudioMetadataEmbeddingError.exportFailed(
                                        writerBox.value.error?.localizedDescription ?? "Unknown writer failure"
                                    )
                                )
                            }
                        }
                        return
                    }
                }
            }
        }

        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: outputURL)
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw AudioMetadataEmbeddingError.exportFailed("Replace failed: \(error.localizedDescription)")
        }
    }

    private func buildMP4MetadataItems(metadata: LocalBookMetadata, coverData: Data?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func addCommon(_ key: AVMetadataKey, _ value: String) {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = key as (NSCopying & NSObjectProtocol)
            item.value = value as (NSCopying & NSObjectProtocol)
            items.append(item)
        }

        addCommon(.commonKeyTitle, metadata.title)
        if let author = metadata.author, !author.isEmpty { addCommon(.commonKeyArtist, author) }
        if let narrator = metadata.narrator, !narrator.isEmpty {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = AVMetadataKey.commonKeyDescription as (NSCopying & NSObjectProtocol)
            item.value = "Narrator: \(narrator)" as (NSCopying & NSObjectProtocol)
            items.append(item)
        }
        if let desc = metadata.description, !desc.isEmpty {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = AVMetadataKey.commonKeyDescription as (NSCopying & NSObjectProtocol)
            item.value = desc as (NSCopying & NSObjectProtocol)
            items.append(item)
        }

        if let coverData {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = AVMetadataKey.commonKeyArtwork as (NSCopying & NSObjectProtocol)
            item.value = coverData as (NSCopying & NSObjectProtocol)
            items.append(item)
        }

        return items
    }

    private func makeChapterMetadataAdaptor(writer: AVAssetWriter) throws -> AVAssetWriterInputMetadataAdaptor {
        let spec: [[NSString: Any]] = [
            [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: AVMetadataIdentifier.quickTimeMetadataTitle.rawValue,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: kCMMetadataBaseDataType_UTF8 as String,
            ]
        ]

        var formatDescription: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: spec as CFArray,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDescription else {
            throw AudioMetadataEmbeddingError.exportFailed("Failed creating chapter metadata format description")
        }

        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = false

        guard writer.canAdd(input) else {
            throw AudioMetadataEmbeddingError.exportFailed("Cannot add chapter metadata input")
        }
        writer.add(input)

        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }

    private func appendChapters(_ chapters: [LocalChapter], adaptor: AVAssetWriterInputMetadataAdaptor, totalDuration: CMTime) throws {
        let sorted = chapters.sorted(by: { $0.startTime < $1.startTime })

        for (index, ch) in sorted.enumerated() {
            let start = CMTime(seconds: ch.startTime, preferredTimescale: 600)
            let endSeconds: Double
            if ch.endTime > ch.startTime {
                endSeconds = ch.endTime
            } else if index + 1 < sorted.count {
                endSeconds = sorted[index + 1].startTime
            } else {
                endSeconds = totalDuration.seconds
            }

            let end = CMTime(seconds: max(endSeconds, ch.startTime), preferredTimescale: 600)
            let range = CMTimeRange(start: start, end: end)

            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .quickTimeMetadataTitle
            titleItem.value = ch.title as (NSCopying & NSObjectProtocol)
            titleItem.dataType = kCMMetadataBaseDataType_UTF8 as String

            let group = AVTimedMetadataGroup(items: [titleItem], timeRange: range)
            _ = adaptor.append(group)
        }

        adaptor.assetWriterInput.markAsFinished()
    }
}

private enum ID3v2 {
    static func detectExistingTag(in data: Data) -> (audioStartOffset: Int, tagSize: Int) {
        guard data.count >= 10 else { return (0, 0) }
        let header = data.subdata(in: 0..<10)
        if header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 {
            let size = Int(decodeSyncSafe(header[6...9]))
            let total = 10 + size
            if total <= data.count {
                return (total, size)
            }
        }
        return (0, 0)
    }

    static func buildTagV24(
        title: String,
        author: String?,
        narrator: String?,
        series: String?,
        seriesNumber: Int?,
        publishedYear: Int?,
        genres: [String]?,
        description: String?,
        publisher: String?,
        isbn: String?,
        asin: String?,
        coverData: Data?,
        chapters: [LocalChapter]?
    ) -> Data {
        var frames = Data()

        frames.append(textFrame(id: "TIT2", value: title))
        if let author, !author.isEmpty {
            frames.append(textFrame(id: "TPE1", value: author))
        }
        if let publisher, !publisher.isEmpty {
            frames.append(textFrame(id: "TPUB", value: publisher))
        }
        if let year = publishedYear {
            frames.append(textFrame(id: "TDRC", value: String(year)))
        }
        if let genres, !genres.isEmpty {
            frames.append(textFrame(id: "TCON", value: genres.joined(separator: ", ")))
        }
        if let description, !description.isEmpty {
            frames.append(commentFrame(value: description))
        }
        if let narrator, !narrator.isEmpty {
            frames.append(userTextFrame(description: "NARRATOR", value: narrator))
        }
        if let series, !series.isEmpty {
            frames.append(userTextFrame(description: "SERIES", value: series))
        }
        if let seriesNumber {
            frames.append(userTextFrame(description: "SERIES_PART", value: String(seriesNumber)))
        }
        if let isbn, !isbn.isEmpty {
            frames.append(userTextFrame(description: "ISBN", value: isbn))
        }
        if let asin, !asin.isEmpty {
            frames.append(userTextFrame(description: "ASIN", value: asin))
        }
        if let coverData {
            frames.append(apicFrame(imageData: coverData))
        }

        if let chapters, !chapters.isEmpty {
            let sorted = chapters.sorted(by: { $0.startTime < $1.startTime })
            let chapFrames = chapterFrames(sorted)
            frames.append(chapFrames)
        }

        var tag = Data()
        tag.append(contentsOf: [0x49, 0x44, 0x33])
        tag.append(contentsOf: [0x04, 0x00])
        tag.append(0x00)
        tag.append(encodeSyncSafe(UInt32(frames.count)))
        tag.append(frames)
        return tag
    }

    private static func textFrame(id: String, value: String) -> Data {
        var payload = Data()
        payload.append(0x03)
        payload.append(value.data(using: .utf8) ?? Data())
        return frame(id: id, payload: payload)
    }

    private static func userTextFrame(description: String, value: String) -> Data {
        var payload = Data()
        payload.append(0x03)
        payload.append(description.data(using: .utf8) ?? Data())
        payload.append(0x00)
        payload.append(value.data(using: .utf8) ?? Data())
        return frame(id: "TXXX", payload: payload)
    }

    private static func commentFrame(value: String) -> Data {
        var payload = Data()
        payload.append(0x03)
        payload.append(contentsOf: [0x65, 0x6E, 0x67])
        payload.append(0x00)
        payload.append(value.data(using: .utf8) ?? Data())
        return frame(id: "COMM", payload: payload)
    }

    private static func apicFrame(imageData: Data) -> Data {
        let mime = guessMimeType(imageData: imageData)
        var payload = Data()
        payload.append(0x03)
        payload.append(mime.data(using: .utf8) ?? Data())
        payload.append(0x00)
        payload.append(0x03)
        payload.append(0x00)
        payload.append(imageData)
        return frame(id: "APIC", payload: payload)
    }

    private static func chapterFrames(_ chapters: [LocalChapter]) -> Data {
        var out = Data()
        var childIDs: [String] = []

        let toMS: (TimeInterval) -> UInt32 = { UInt32(max(0, ($0 * 1000.0).rounded())) }

        for (idx, chapter) in chapters.enumerated() {
            let elementId = String(format: "chp%04d", idx + 1)
            childIDs.append(elementId)

            var payload = Data()
            payload.append(elementId.data(using: .utf8) ?? Data())
            payload.append(0x00)

            let start = toMS(chapter.startTime)
            let end = toMS(max(chapter.endTime, chapter.startTime))
            payload.append(contentsOf: start.bigEndianBytes)
            payload.append(contentsOf: end.bigEndianBytes)
            payload.append(contentsOf: UInt32(0xFFFF_FFFF).bigEndianBytes)
            payload.append(contentsOf: UInt32(0xFFFF_FFFF).bigEndianBytes)

            payload.append(textFrame(id: "TIT2", value: chapter.title))

            out.append(frame(id: "CHAP", payload: payload))
        }

        do {
            let tocId = "toc"
            var payload = Data()
            payload.append(tocId.data(using: .utf8) ?? Data())
            payload.append(0x00)
            payload.append(0x03)
            payload.append(UInt8(min(childIDs.count, 255)))
            for id in childIDs {
                payload.append(id.data(using: .utf8) ?? Data())
                payload.append(0x00)
            }
            payload.append(textFrame(id: "TIT2", value: "Chapters"))
            out.append(frame(id: "CTOC", payload: payload))
        }

        return out
    }

    private static func frame(id: String, payload: Data) -> Data {
        var frame = Data()
        frame.append(id.data(using: .ascii) ?? Data())
        frame.append(encodeSyncSafe(UInt32(payload.count)))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(payload)
        return frame
    }

    private static func encodeSyncSafe(_ value: UInt32) -> Data {
        let b0 = UInt8((value >> 21) & 0x7F)
        let b1 = UInt8((value >> 14) & 0x7F)
        let b2 = UInt8((value >> 7) & 0x7F)
        let b3 = UInt8(value & 0x7F)
        return Data([b0, b1, b2, b3])
    }

    private static func decodeSyncSafe(_ bytes: Data.SubSequence) -> UInt32 {
        guard bytes.count == 4 else { return 0 }
        let b = Array(bytes)
        return (UInt32(b[0] & 0x7F) << 21)
            | (UInt32(b[1] & 0x7F) << 14)
            | (UInt32(b[2] & 0x7F) << 7)
            | UInt32(b[3] & 0x7F)
    }

    private static func guessMimeType(imageData: Data) -> String {
        if imageData.count >= 3 {
            let b0 = imageData[imageData.startIndex]
            let b1 = imageData[imageData.startIndex.advanced(by: 1)]
            let b2 = imageData[imageData.startIndex.advanced(by: 2)]
            if b0 == 0xFF, b1 == 0xD8, b2 == 0xFF {
                return "image/jpeg"
            }
        }
        if imageData.count >= 4 {
            let b0 = imageData[imageData.startIndex]
            let b1 = imageData[imageData.startIndex.advanced(by: 1)]
            let b2 = imageData[imageData.startIndex.advanced(by: 2)]
            let b3 = imageData[imageData.startIndex.advanced(by: 3)]
            if b0 == 0x89, b1 == 0x50, b2 == 0x4E, b3 == 0x47 {
                return "image/png"
            }
        }
        return "image/jpeg"
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        let be = self.bigEndian
        return [
            UInt8((be >> 24) & 0xFF),
            UInt8((be >> 16) & 0xFF),
            UInt8((be >> 8) & 0xFF),
            UInt8(be & 0xFF),
        ]
    }
}
