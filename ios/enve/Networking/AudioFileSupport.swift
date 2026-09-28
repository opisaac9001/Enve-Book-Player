import AVFoundation
import Foundation

enum AudioFileSupport {
    static func embeddedChapters(in asset: AVURLAsset) async throws -> [Chapter] {
        let startTime = Date()
        let chapterLocales = try await asset.load(.availableChapterLocales)

        guard Date().timeIntervalSince(startTime) < 10 else {
            throw NSError(
                domain: "ChapterExtraction",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Timeout loading chapter locales"]
            )
        }

        var extractedChapters: [Chapter] = []

        for locale in chapterLocales {
            let chapterGroups = try await asset.loadChapterMetadataGroups(
                withTitleLocale: locale,
                containingItemsWithCommonKeys: [.commonKeyArtwork]
            )

            for (index, group) in chapterGroups.enumerated() {
                let chapterStartTime = CMTimeGetSeconds(group.timeRange.start)
                let duration = CMTimeGetSeconds(group.timeRange.duration)

                var title = "Chapter \(index + 1)"
                if let titleItem = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
                    let titleValue = try? await titleItem.load(.value) as? String
                {
                    title = titleValue
                }

                extractedChapters.append(
                    Chapter(
                        id: String(index),
                        start: chapterStartTime,
                        end: chapterStartTime + duration,
                        title: title,
                        index: index
                    )
                )
            }

            if !extractedChapters.isEmpty { break }
        }

        return extractedChapters
    }

    static func chaptersWithResolvedEnds(_ chapters: [Chapter], bookDuration: TimeInterval) -> [Chapter] {
        let sorted = chapters.sorted { $0.start < $1.start }
        return sorted.enumerated().map { index, chapter in
            let end: TimeInterval
            if chapter.end > chapter.start {
                end = chapter.end
            } else if index + 1 < sorted.count {
                end = sorted[index + 1].start
            } else {
                end = bookDuration
            }
            return Chapter(id: chapter.id, start: chapter.start, end: end, title: chapter.title, index: index)
        }
    }

    nonisolated static func mimeType(forExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "m4a", "m4b", "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg", "oga", "opus", "vorbis": return "audio/ogg"
        case "wav", "wave": return "audio/wav"
        default: return nil
        }
    }
}
