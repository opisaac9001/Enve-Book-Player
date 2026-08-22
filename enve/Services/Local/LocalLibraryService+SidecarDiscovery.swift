import Foundation
import Logging

extension LocalLibraryService {
    nonisolated func sidecarCandidatePaths(
        forAudioFilePath filePath: String,
        includeFolderMetadata: Bool = true
    ) -> [String] {
        let url = URL(fileURLWithPath: filePath)
        let baseName = url.deletingPathExtension().lastPathComponent
        let fullName = url.lastPathComponent
        let dir = url.deletingLastPathComponent()

        let narratorSidecar = dir.appendingPathComponent("\(baseName).sidecar.json").path

        let narratorUnderscoreSidecar = dir.appendingPathComponent("\(baseName)._sidecar.json").path
        let narratorUnderscoreSidecarWithExt = dir.appendingPathComponent("\(fullName)._sidecar.json").path

        let genericJson = dir.appendingPathComponent("\(baseName).json").path
        let genericJsonWithExt = dir.appendingPathComponent("\(fullName).json").path

        let metadataJson = dir.appendingPathComponent("\(baseName).metadata.json").path
        let metadataJsonWithExt = dir.appendingPathComponent("\(fullName).metadata.json").path
        let chaptersJson = dir.appendingPathComponent("\(baseName).chapters.json").path
        let chaptersJsonWithExt = dir.appendingPathComponent("\(fullName).chapters.json").path

        let folderMetadataJson = dir.appendingPathComponent("metadata.json").path
        let folderAbsJson = dir.appendingPathComponent("metadata.abs.json").path
        let folderInfoJson = dir.appendingPathComponent("info.json").path
        let folderBookJson = dir.appendingPathComponent("book.json").path
        let folderAudiobookJson = dir.appendingPathComponent("audiobook.json").path

        var candidates = [
            narratorSidecar,
            narratorUnderscoreSidecar,
            narratorUnderscoreSidecarWithExt,
            genericJson,
            genericJsonWithExt,
            metadataJson,
            metadataJsonWithExt,
            chaptersJson,
            chaptersJsonWithExt,
        ]
        if includeFolderMetadata {
            candidates.append(contentsOf: [
                folderMetadataJson,
                folderAbsJson,
                folderInfoJson,
                folderBookJson,
                folderAudiobookJson,
            ])
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    nonisolated func companionCoverPath(
        forAudioFilePath filePath: String,
        includeFolderCover: Bool = true
    ) -> String? {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: filePath)
        let baseName = url.deletingPathExtension().lastPathComponent
        let fullName = url.lastPathComponent
        let dir = url.deletingLastPathComponent()

        var names = [baseName, fullName]
        if includeFolderCover {
            names.append(contentsOf: ["cover", "folder", "front", "album", "artwork"])
        }
        let candidates = names.flatMap { name in
            ["jpg", "jpeg", "png", "webp"].map {
                dir.appendingPathComponent("\(name).\($0)").path
            }
        }

        return candidates.first(where: { fileManager.fileExists(atPath: $0) })
    }

    func loadSidecarMetadata(from sidecarPath: String) async throws -> LocalBookMetadata {
        let data = try Data(contentsOf: URL(fileURLWithPath: sidecarPath))
        AppLogger.network.debug("Loaded \(data.count) bytes from sidecar: \(URL(fileURLWithPath: sidecarPath).lastPathComponent)")

        AppLogger.network.debug("Trying Audible metadata format...")
        do {
            let audible = try await decodeAudibleMetadata(from: data)
            AppLogger.network.debug("Decoded as Audible metadata")
            return audible
        } catch {
            AppLogger.network.error("Not Audible format: \(error.localizedDescription)")
        }

        if let native = try? decodeSidecar(from: data) {
            AppLogger.network.info("Decoded as Native Narrator sidecar")
            return native.metadata
        }

        if let direct = try? decodeLocalBookMetadata(from: data) {
            AppLogger.network.info("Decoded as raw LocalBookMetadata")
            return direct
        }

        AppLogger.network.info("Trying Generic format...")
        do {
            let generic = try await decodeGenericSidecarMetadata(from: data)
            AppLogger.network.info("Decoded as Generic sidecar")
            return generic
        } catch {
            AppLogger.network.error("Generic decode failed: \(error)")
        }

        throw NSError(
            domain: "LocalLibraryService",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: "Unrecognized sidecar JSON format"
            ]
        )
    }

    private nonisolated func decodeLocalBookMetadata(from data: Data) throws -> LocalBookMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LocalBookMetadata.self, from: data)
    }

    private func decodeGenericSidecarMetadata(from data: Data) async throws -> LocalBookMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let generic = try decoder.decode(GenericSidecar.self, from: data)

        if let absMetadata = generic.metadata {
            return decodeAudiobookshelfMetadata(absMetadata, media: generic.media)
        }

        let rawChapters = generic.chapters ?? generic.media?.chapters

        let chapters: [LocalChapter]? = await MainActor.run {
            rawChapters?.compactMap { ch in
                let start = ch.startTime ?? ch.start ?? 0
                let end = ch.endTime ?? ch.end ?? 0

                let duration = ch.duration ?? (end > start ? (end - start) : nil) ?? 0
                let computedEnd: TimeInterval = end > start ? end : (start + duration)

                let title = (ch.title ?? ch.name ?? "Chapter").trimmingCharacters(in: .whitespacesAndNewlines)
                if duration <= 0 { return nil }

                return LocalChapter(
                    title: title.isEmpty ? "Chapter" : title,
                    startTime: start,
                    endTime: computedEnd,
                    duration: duration
                )
            }
        }

        let duration: TimeInterval? = {
            if let d = generic.duration { return d }
            if let d = generic.lengthInSeconds { return d }
            if let ms = generic.runtimeLengthMs { return TimeInterval(ms) / 1000.0 }
            if let d = generic.media?.duration { return d }
            if let chapters, let maxEnd = chapters.map({ $0.endTime }).max() { return maxEnd }
            return nil
        }()

        let seriesNumber: Int? = {
            if let sn = generic.seriesNumber { return sn }
            if let seq = generic.seriesSequence, let sn = Int(seq) { return sn }
            return nil
        }()
        let seriesSequence: String? = generic.seriesSequence ?? generic.seriesNumber.map(String.init)

        let publishedYear: Int? = {
            if let y = generic.publishedYear { return y }
            if let y = generic.year { return y }
            if let y = generic.publishYear { return y }
            if let rd = generic.releaseDate, let y = Int(rd.prefix(4)) { return y }
            return nil
        }()

        let description: String? = generic.description ?? generic.summary ?? generic.synopsis

        let narrator: String? = generic.narrator ?? generic.narratorName ?? generic.narrators?.first

        let author: String? = generic.author ?? generic.authorName ?? generic.authors?.first

        let coverPath: String? = generic.coverImagePath ?? generic.cover ?? generic.coverPath

        let genres: [String]? = generic.genres ?? generic.tags

        return LocalBookMetadata(
            title: generic.title ?? generic.bookTitle ?? generic.name ?? "Unknown Title",
            author: author,
            narrator: narrator,
            description: description,
            series: generic.series ?? generic.seriesName,
            seriesNumber: seriesNumber,
            seriesSequence: seriesSequence,
            publishedYear: publishedYear,
            genres: genres,
            publisher: generic.publisher,
            isbn: generic.isbn,
            asin: generic.asin,
            duration: duration,
            chapters: chapters,
            coverImagePath: coverPath,
            lastUpdated: generic.lastUpdated ?? Date(),
            metadataVersion: generic.metadataVersion ?? "external"
        )
    }

    private nonisolated func decodeAudiobookshelfMetadata(
        _ metadata: AudiobookshelfMetadata,
        media: AudiobookshelfMedia?
    ) -> LocalBookMetadata {
        let author: String? = metadata.authors?.compactMap { $0.name }.first

        let series: String? = metadata.series?.first?.name
        let seriesSequence: String? = metadata.series?.first?.sequence
        let seriesNumber: Int? = seriesSequence.flatMap { Double($0) }.map { Int($0) }

        let publishedYear: Int? = metadata.publishedYear.flatMap { Int($0) }

        let narrator: String? = metadata.narrators?.first

        return LocalBookMetadata(
            title: metadata.title ?? "Unknown Title",
            author: author,
            narrator: narrator,
            description: metadata.description,
            series: series,
            seriesNumber: seriesNumber,
            seriesSequence: seriesSequence,
            publishedYear: publishedYear,
            genres: metadata.genres,
            publisher: metadata.publisher,
            isbn: metadata.isbn,
            asin: metadata.asin,
            duration: media?.duration,
            chapters: nil,
            coverImagePath: nil,
            lastUpdated: Date(),
            metadataVersion: "audiobookshelf"
        )
    }

    private func decodeAudibleMetadata(from data: Data) async throws -> LocalBookMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let audible = try decoder.decode(AudibleMetadata.self, from: data)

        AppLogger.network.debug("Decoded external metadata:")
        AppLogger.network.debug(
            "Metadata diagnosticId=\(DiagnosticLogSanitizer.identifier(for: [audible.title, audible.asin].compactMap { $0 }.joined(separator: "|")))"
        )
        AppLogger.network.debug("Authors: \(audible.authors?.count ?? 0)")
        AppLogger.network.debug("Narrators: \(audible.narrators?.count ?? 0)")
        AppLogger.network.debug("ChapterInfo: \(audible.ChapterInfo != nil ? "present" : "nil")")
        AppLogger.network.debug("Chapters count: \(audible.ChapterInfo?.chapters?.count ?? 0)")

        let author = audible.authors?.first?.name

        let narrator = audible.narrators?.compactMap { $0.name }.joined(separator: ", ")

        let series = audible.series?.first?.title
        let seriesRawSequence: String? = audible.series?.first?.sequence
        let seriesNumber = seriesRawSequence.flatMap { Double($0) }.map { Int($0) }

        let publishedYear: Int? = {
            if let date = audible.release_date, let year = Int(date.prefix(4)) {
                return year
            }
            if let date = audible.publication_datetime, let year = Int(date.prefix(4)) {
                return year
            }
            return nil
        }()

        let description = audible.publisher_summary ?? audible.merchandising_summary

        let duration: TimeInterval? = {
            if let mins = audible.runtime_length_min {
                return TimeInterval(mins * 60)
            }
            if let sec = audible.ChapterInfo?.runtime_length_sec {
                return TimeInterval(sec)
            }
            return nil
        }()

        let chapters: [LocalChapter]? = {
            let result = audible.ChapterInfo?.chapters?.compactMap { ch -> LocalChapter? in
                guard let title = ch.title,
                    let lengthMs = ch.length_ms,
                    let startMs = ch.start_offset_ms
                else {
                    AppLogger.network.warning(
                        "Skipping chapter with missing data: hasTitle=\(ch.title != nil), hasLength=\(ch.length_ms != nil), hasStart=\(ch.start_offset_ms != nil)"
                    )
                    return nil
                }

                let startTime = TimeInterval(startMs) / 1000.0
                let chDuration = TimeInterval(lengthMs) / 1000.0
                let endTime = startTime + chDuration

                return LocalChapter(
                    title: title,
                    startTime: startTime,
                    endTime: endTime,
                    duration: chDuration
                )
            }
            AppLogger.network.debug("Extracted \(result?.count ?? 0) chapters")
            return result
        }()

        let metadata = LocalBookMetadata(
            title: audible.title ?? "Unknown Title",
            author: author,
            narrator: narrator,
            description: description,
            series: series,
            seriesNumber: seriesNumber,
            seriesSequence: seriesRawSequence,
            publishedYear: publishedYear,
            genres: nil,
            publisher: audible.publisher_name,
            isbn: nil,
            asin: audible.asin,
            duration: duration,
            chapters: chapters,
            coverImagePath: nil,
            lastUpdated: Date(),
            metadataVersion: "audible"
        )

        AppLogger.network.debug("Created LocalBookMetadata with \(metadata.chapters?.count ?? 0) chapters")

        return metadata
    }
}

nonisolated private struct GenericSidecar: Codable {
    var title: String?
    var bookTitle: String?
    var name: String?

    var author: String?
    var authors: [String]?
    var authorName: String?

    var narrator: String?
    var narrators: [String]?
    var narratorName: String?

    var description: String?
    var summary: String?
    var synopsis: String?

    var series: String?
    var seriesName: String?
    var seriesNumber: Int?
    var seriesSequence: String?

    var publishedYear: Int?
    var year: Int?
    var releaseDate: String?
    var publishYear: Int?

    var genres: [String]?
    var tags: [String]?
    var publisher: String?
    var isbn: String?
    var asin: String?
    var duration: TimeInterval?
    var lengthInSeconds: TimeInterval?
    var runtimeLengthMs: Int?

    var chapters: [GenericChapter]?

    var coverImagePath: String?
    var cover: String?
    var coverPath: String?

    var lastUpdated: Date?
    var metadataVersion: String?

    var metadata: AudiobookshelfMetadata?
    var media: AudiobookshelfMedia?
}

nonisolated private struct AudiobookshelfMetadata: Codable {
    var title: String?
    var subtitle: String?
    var authors: [AudiobookshelfAuthor]?
    var narrators: [String]?
    var series: [AudiobookshelfSeries]?
    var genres: [String]?
    var publishedYear: String?
    var publisher: String?
    var description: String?
    var isbn: String?
    var asin: String?
    var language: String?
}

nonisolated private struct AudiobookshelfAuthor: Codable {
    var name: String?
}

nonisolated private struct AudiobookshelfSeries: Codable {
    var name: String?
    var sequence: String?
}

nonisolated private struct AudiobookshelfMedia: Codable {
    var duration: TimeInterval?
    var chapters: [GenericChapter]?
}

nonisolated private struct GenericChapter: Codable {
    var id: String?
    var title: String?
    var name: String?
    var startTime: TimeInterval?
    var start: TimeInterval?
    var endTime: TimeInterval?
    var end: TimeInterval?
    var duration: TimeInterval?
    var length_ms: Int?
    var start_offset_ms: Int?
    var start_offset_sec: Int?
}

nonisolated private struct AudibleMetadata: Codable {
    var title: String?
    var asin: String?
    var authors: [AudibleAuthor]?
    var narrators: [AudibleNarrator]?
    var series: [AudibleSeries]?
    var publisher_name: String?
    var publisher_summary: String?
    var merchandising_summary: String?
    var runtime_length_min: Int?
    var release_date: String?
    var publication_datetime: String?
    var language: String?
    var format_type: String?
    var ChapterInfo: AudibleChapterInfo?
}

nonisolated private struct AudibleAuthor: Codable {
    var name: String?
    var asin: String?
}

nonisolated private struct AudibleNarrator: Codable {
    var name: String?
}

nonisolated private struct AudibleSeries: Codable {
    var title: String?
    var sequence: String?
    var asin: String?
    var url: String?
}

nonisolated private struct AudibleChapterInfo: Codable {
    var chapters: [AudibleChapter]?
    var runtime_length_ms: Int64?
    var runtime_length_sec: Int64?
    var is_accurate: Bool?
    var brandIntroDurationMs: Int?
    var brandOutroDurationMs: Int?
}

nonisolated private struct AudibleChapter: Codable {
    var title: String?
    var length_ms: Int64?
    var start_offset_ms: Int64?
    var start_offset_sec: Int64?
    var chapters: [AudibleChapter]?
}
