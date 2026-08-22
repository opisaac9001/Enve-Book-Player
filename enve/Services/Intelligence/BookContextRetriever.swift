import Foundation

@MainActor
final class BookContextRetriever {
    static let shared = BookContextRetriever()

    private let transcriptStore = BookTranscriptStore.shared
    private let ebookContextStore = EbookContextStore.shared

    private init() {}

    func context(for book: Book, scope: BookIntelligenceScope, currentTime: TimeInterval) -> BookContextResult {
        context(for: book, scope: scope, range: contextRange(for: book, scope: scope, currentTime: currentTime))
    }

    func context(for book: Book, scope: BookIntelligenceScope, range: ClosedRange<TimeInterval>) -> BookContextResult {
        if book.mediaType == .ebook {
            return ebookContext(for: book, scope: scope, range: range)
        }

        let transcript = transcriptStore.loadTranscript(bookStableId: book.stableId)

        let selectedSegments = (transcript?.segments ?? [])
            .filter { $0.endTime >= range.lowerBound && $0.startTime <= range.upperBound }
            .sorted { $0.startTime < $1.startTime }

        let text =
            selectedSegments
            .map { "[\(formatTime($0.startTime))] \($0.text)" }
            .joined(separator: "\n")

        return BookContextResult(
            scope: scope,
            source: .audiobookTranscript,
            range: range,
            text: trimmedContext(text),
            segmentCount: selectedSegments.count
        )
    }

    func contextRange(for book: Book, scope: BookIntelligenceScope, currentTime: TimeInterval) -> ClosedRange<TimeInterval> {
        if book.mediaType == .ebook {
            let chunks = ebookChunks(for: book).sorted { $0.startProgress < $1.startProgress }
            return ebookRangeForScope(scope, currentProgress: min(max(currentTime, 0), 1), chunks: chunks)
        }

        let transcript = transcriptStore.loadTranscript(bookStableId: book.stableId)
        let duration = transcript?.manifest.duration ?? book.duration ?? currentTime
        let chapters = normalizedChapters(for: book, duration: duration)
        return rangeForScope(scope, currentTime: currentTime, duration: duration, chapters: chapters)
    }

    func catchUpRange(for book: Book, currentTime: TimeInterval) -> ClosedRange<TimeInterval> {
        if book.mediaType == .ebook {
            let chunks = ebookChunks(for: book).sorted { $0.startProgress < $1.startProgress }
            let progress = min(max(currentTime, 0), 1)
            guard !chunks.isEmpty else { return progress...progress }
            let currentIndex = ebookChunkIndex(at: progress, chunks: chunks) ?? 0
            guard currentIndex > 0 else {
                return max(0, progress - 0.05)...progress
            }
            let previous = chunks[currentIndex - 1]
            return max(previous.startProgress, previous.endProgress - 0.05)...previous.endProgress
        }

        let transcript = transcriptStore.loadTranscript(bookStableId: book.stableId)
        let duration = transcript?.manifest.duration ?? book.duration ?? currentTime
        let chapters = normalizedChapters(for: book, duration: duration)
        let clampedCurrent = min(max(0, currentTime), max(duration, currentTime))
        guard let currentIndex = chapters.lastIndex(where: { $0.start <= clampedCurrent }),
            currentIndex > 0
        else {
            return max(0, clampedCurrent - 120)...clampedCurrent
        }
        let previous = chapters[currentIndex - 1]
        return max(previous.start, previous.end - 180)...previous.end
    }

    func librarianRange(
        for book: Book,
        question: String,
        scope: BookIntelligenceScope,
        currentTime: TimeInterval,
        preferredRange: ClosedRange<TimeInterval>? = nil
    ) -> ClosedRange<TimeInterval> {
        guard book.mediaType == .audiobook else {
            return preferredRange ?? contextRange(for: book, scope: scope, currentTime: currentTime)
        }

        let normalizedQuestion =
            question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let baseRange = preferredRange ?? contextRange(for: book, scope: scope, currentTime: currentTime)

        if normalizedQuestion.contains("catch me up") || normalizedQuestion.contains("catch up") || normalizedQuestion.contains("catch-up")
        {
            return catchUpRange(for: book, currentTime: currentTime)
        }

        switch scope {
        case .previousChapter:
            return trailingWindow(in: baseRange, maxDuration: 240)
        case .currentChapterSoFar:
            return trailingWindow(in: baseRange, maxDuration: 180)
        case .lastTenMinutes:
            return trailingWindow(in: baseRange, maxDuration: 120)
        case .bookSoFar:
            return trailingWindow(in: baseRange, maxDuration: 240)
        }
    }

    func transcriptSegments(for book: Book) -> [TranscriptSegment] {
        transcriptStore.loadTranscript(bookStableId: book.stableId)?.segments ?? []
    }

    func ebookChunks(for book: Book) -> [EbookContextChunk] {
        ebookContextStore.loadContext(bookStableId: book.stableId)?.chunks ?? []
    }

    private func ebookContext(for book: Book, scope: BookIntelligenceScope, range: ClosedRange<Double>) -> BookContextResult {
        let chunks = (ebookContextStore.loadContext(bookStableId: book.stableId)?.chunks ?? [])
            .sorted { $0.startProgress < $1.startProgress }
        let selectedChunks = chunks.filter { $0.endProgress >= range.lowerBound && $0.startProgress <= range.upperBound }

        let text =
            selectedChunks
            .map { chunk -> String in
                let title = chunk.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = title?.isEmpty == false ? "[\(title!)] " : ""
                return label + boundedText(for: chunk, in: range)
            }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        return BookContextResult(
            scope: scope,
            source: .ebookText,
            range: range,
            text: trimmedContext(text),
            segmentCount: selectedChunks.count
        )
    }

    private func rangeForScope(
        _ scope: BookIntelligenceScope,
        currentTime: TimeInterval,
        duration: TimeInterval,
        chapters: [Chapter]
    ) -> ClosedRange<TimeInterval> {
        let clampedCurrent = min(max(0, currentTime), max(duration, currentTime))

        switch scope {
        case .lastTenMinutes:
            return max(0, clampedCurrent - 600)...clampedCurrent
        case .bookSoFar:
            return 0...clampedCurrent
        case .currentChapterSoFar:
            guard let chapter = chapter(at: clampedCurrent, chapters: chapters) else {
                return max(0, clampedCurrent - 600)...clampedCurrent
            }
            return chapter.start...min(clampedCurrent, chapter.end)
        case .previousChapter:
            guard let currentIndex = chapters.lastIndex(where: { $0.start <= clampedCurrent }),
                currentIndex > 0
            else {
                return 0...clampedCurrent
            }
            let previous = chapters[currentIndex - 1]
            return previous.start...previous.end
        }
    }

    private func ebookRangeForScope(
        _ scope: BookIntelligenceScope,
        currentProgress: Double,
        chunks: [EbookContextChunk]
    ) -> ClosedRange<Double> {
        guard !chunks.isEmpty else { return currentProgress...currentProgress }
        let currentIndex = ebookChunkIndex(at: currentProgress, chunks: chunks) ?? 0
        let current = chunks[currentIndex]

        switch scope {
        case .lastTenMinutes:
            return max(0, currentProgress - 0.05)...currentProgress
        case .bookSoFar:
            return 0...currentProgress
        case .currentChapterSoFar:
            return current.startProgress...min(currentProgress, current.endProgress)
        case .previousChapter:
            guard currentIndex > 0 else {
                return 0...currentProgress
            }
            let previous = chunks[currentIndex - 1]
            return previous.startProgress...previous.endProgress
        }
    }

    private func ebookChunkIndex(at progress: Double, chunks: [EbookContextChunk]) -> Int? {
        var best: Int?
        for index in chunks.indices {
            if chunks[index].startProgress <= progress + 0.0001 {
                best = index
            } else {
                break
            }
        }
        return best
    }

    private func boundedText(for chunk: EbookContextChunk, in range: ClosedRange<Double>) -> String {
        var text = chunk.text
        let span = max(chunk.endProgress - chunk.startProgress, 0.0001)

        if range.lowerBound > chunk.startProgress + 0.0001 {
            let lowerFraction = min(max((range.lowerBound - chunk.startProgress) / span, 0), 1)
            text = suffix(text, fromFraction: lowerFraction)
        }

        if range.upperBound < chunk.endProgress - 0.0001 {
            let upperFraction = min(max((range.upperBound - chunk.startProgress) / span, 0), 1)
            text = prefix(text, throughFraction: upperFraction)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prefix(_ text: String, throughFraction fraction: Double) -> String {
        guard fraction < 0.995 else { return text }
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return text }
        let count = max(1, min(words.count, Int((Double(words.count) * fraction).rounded(.up))))
        return words.prefix(count).joined(separator: " ")
    }

    private func suffix(_ text: String, fromFraction fraction: Double) -> String {
        guard fraction > 0.005 else { return text }
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return text }
        let start = max(0, min(words.count - 1, Int((Double(words.count) * fraction).rounded(.down))))
        return words[start...].joined(separator: " ")
    }

    private func chapter(at time: TimeInterval, chapters: [Chapter]) -> Chapter? {
        chapters.first { $0.start <= time && time < $0.end }
            ?? chapters.last { $0.start <= time }
    }

    private func normalizedChapters(for book: Book, duration: TimeInterval) -> [Chapter] {
        guard let chapters = book.chapters, !chapters.isEmpty else { return [] }
        let sorted = chapters.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.end < rhs.end }
            return lhs.start < rhs.start
        }

        return sorted.enumerated().map { index, chapter in
            let start = max(0, chapter.start)
            let nextStart = sorted.indices.contains(index + 1) ? max(sorted[index + 1].start, start) : nil
            let fallbackEnd = nextStart ?? (duration > 0 ? duration : start + 1)
            return Chapter(
                id: chapter.id,
                start: start,
                end: max(chapter.end, fallbackEnd, start + 1),
                title: chapter.title,
                index: chapter.index
            )
        }
    }

    private func trailingWindow(in range: ClosedRange<TimeInterval>, maxDuration: TimeInterval) -> ClosedRange<TimeInterval> {
        let upperBound = max(range.upperBound, range.lowerBound)
        return max(range.lowerBound, upperBound - maxDuration)...upperBound
    }

    private func trimmedContext(_ text: String) -> String {

        let maxCharacters = 24_000
        guard text.count > maxCharacters else { return text }
        return String(text.suffix(maxCharacters))
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let total = Int(max(0, time))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
