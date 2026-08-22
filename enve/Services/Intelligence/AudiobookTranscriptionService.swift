import AVFoundation
import CoreMedia
import Foundation

#if os(iOS)
import Speech
#endif

enum AudiobookTranscriptionError: LocalizedError {
    case unsupportedOS
    case speechAuthorizationDenied
    case speechTranscriberUnavailable
    case transcriptionBusy
    case localeUnsupported
    case assetUnavailable
    case invalidTrackURL

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Read-along transcripts require iOS 26 or later."
        case .speechAuthorizationDenied:
            return "Speech Recognition permission is required to generate read-along transcripts."
        case .speechTranscriberUnavailable:
            return "On-device transcription is not available on this device."
        case .transcriptionBusy:
            return "Enve is already generating another transcript. Try Quick Sync again when it finishes."
        case .localeUnsupported:
            return "On-device transcription is not available for this book's language."
        case .assetUnavailable:
            return "The on-device speech model for this language is not installed."
        case .invalidTrackURL:
            return "The local audiobook file could not be opened."
        }
    }
}

@MainActor
@Observable
final class AudiobookTranscriptionService {
    static let shared = AudiobookTranscriptionService()
    private let maxOnDemandWindowDuration: TimeInterval = 240

    private(set) var activeBookStableId: String?
    private(set) var progressByBookId: [String: Double] = [:]
    private(set) var statusByBookId: [String: String] = [:]

    @ObservationIgnored private let store = BookTranscriptStore.shared
    @ObservationIgnored private let resolver = AudiobookAudioTimelineResolver.shared

    private init() {}

    func isGenerating(bookStableId: String) -> Bool {
        activeBookStableId == bookStableId
    }

    func progress(for bookStableId: String) -> Double {
        progressByBookId[bookStableId] ?? 0
    }

    func statusText(for bookStableId: String) -> String? {
        statusByBookId[bookStableId]
    }

    func transcribeWindow(
        for book: Book,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) async throws -> [TranscriptSegment] {
        #if os(iOS)
        guard #available(iOS 26.0, *) else {
            throw AudiobookTranscriptionError.unsupportedOS
        }
        guard activeBookStableId == nil else {
            throw AudiobookTranscriptionError.transcriptionBusy
        }

        let locale = try await supportedLocale(for: book)
        let tracks = try await resolver.localTracks(for: book)
        let start = min(max(startTime, 0), tracks.totalDuration)
        let end = min(max(endTime, start), tracks.totalDuration)
        let chapters = normalizedChapters(for: book, duration: tracks.totalDuration)
        var segments: [TranscriptSegment] = []
        for job in jobs(in: start..<end, tracks: tracks) {
            try Task.checkCancellation()
            segments.append(contentsOf: try await transcribeTrack(job, book: book, locale: locale))
        }
        return assignChapters(
            segments: TranscriptSegmentNormalizer.normalize(segments),
            chapters: chapters
        )
        #else
        throw AudiobookTranscriptionError.unsupportedOS
        #endif
    }

    func generateTranscript(for book: Book, startTime: TimeInterval = 0, endTime: TimeInterval? = nil) async throws -> BookTranscript {
        #if os(iOS)
        guard #available(iOS 26.0, *) else {
            throw AudiobookTranscriptionError.unsupportedOS
        }

        guard book.mediaType == .audiobook else {
            throw AudiobookTimelineError.noPlayableAudio
        }

        let locale = try await supportedLocale(for: book)
        let tracks = try await resolver.localTracks(for: book)
        let fingerprint = try await resolver.sourceFingerprint(for: book, localeIdentifier: locale.identifier)
        let bookStableId = book.stableId
        let clampedStartTime = min(max(0, startTime), tracks.totalDuration)
        let clampedEndTime = endTime.map { requestedEnd in
            min(max(clampedStartTime, requestedEnd), min(tracks.totalDuration, clampedStartTime + maxOnDemandWindowDuration))
        }

        activeBookStableId = bookStableId
        progressByBookId[bookStableId] = 0
        var completedSegments = store.loadTranscript(bookStableId: bookStableId)?.segments ?? []
        statusByBookId[bookStableId] = "Preparing speech model"
        store.markGenerating(
            bookStableId: bookStableId,
            localeIdentifier: locale.identifier,
            duration: tracks.totalDuration,
            fingerprint: fingerprint
        )

        do {
            let chapters = normalizedChapters(for: book, duration: tracks.totalDuration)
            let transcriptionJobsToRun: [TranscriptionJob]
            if let clampedEndTime {
                let lowerBound = clampedStartTime
                let upperBound = clampedEndTime
                transcriptionJobsToRun = jobs(in: lowerBound..<upperBound, tracks: tracks)
            } else {
                transcriptionJobsToRun = transcriptionJobs(tracks: tracks, chapters: chapters, startTime: clampedStartTime)
            }

            for (offset, job) in transcriptionJobsToRun.enumerated() {
                statusByBookId[bookStableId] = "Transcribing \(job.label)"
                let segments = try await transcribeTrack(job, book: book, locale: locale)
                let assigned = assignChapters(segments: segments, chapters: chapters)
                completedSegments = mergeSegments(completedSegments, assigned)

                try store.savePartialTranscript(
                    bookStableId: bookStableId,
                    localeIdentifier: locale.identifier,
                    duration: tracks.totalDuration,
                    fingerprint: fingerprint,
                    segments: assigned
                )

                progressByBookId[bookStableId] = Double(offset + 1) / Double(max(transcriptionJobsToRun.count, 1))
            }

            let assigned = assignChapters(segments: completedSegments, chapters: chapters)
            if clampedEndTime == nil {
                try store.saveTranscript(
                    bookStableId: bookStableId,
                    localeIdentifier: locale.identifier,
                    duration: tracks.totalDuration,
                    fingerprint: fingerprint,
                    segments: assigned
                )
            } else {
                try store.savePartialTranscript(
                    bookStableId: bookStableId,
                    localeIdentifier: locale.identifier,
                    duration: tracks.totalDuration,
                    fingerprint: fingerprint,
                    segments: assigned
                )
            }

            statusByBookId[bookStableId] = clampedEndTime == nil ? "Transcript ready" : "Transcript context ready"
            activeBookStableId = nil
            return store.loadTranscript(bookStableId: bookStableId)
                ?? BookTranscript(
                    manifest: BookTranscriptManifest(
                        bookStableId: bookStableId,
                        status: .ready,
                        localeIdentifier: locale.identifier,
                        createdAt: Date(),
                        updatedAt: Date(),
                        duration: tracks.totalDuration,
                        segmentCount: assigned.count,
                        sourceFingerprint: fingerprint,
                        failureMessage: nil
                    ),
                    segments: assigned
                )
        } catch {
            store.markFailed(bookStableId: bookStableId, message: error.localizedDescription)
            statusByBookId[bookStableId] = error.localizedDescription
            activeBookStableId = nil
            throw error
        }
        #else
        throw AudiobookTranscriptionError.unsupportedOS
        #endif
    }

    private func transcriptionJobs(tracks: [AudioTrackInfo], chapters: [Chapter], startTime: TimeInterval) -> [TranscriptionJob] {
        let duration = tracks.totalDuration
        let clampedStart = min(max(0, startTime), max(duration, 0))

        guard !chapters.isEmpty else {
            return jobs(in: clampedStart..<duration, tracks: tracks)
                + jobs(in: 0..<clampedStart, tracks: tracks)
        }

        let currentIndex = chapters.lastIndex { $0.start <= clampedStart } ?? chapters.startIndex
        let currentChapter = chapters[currentIndex]
        let forwardEndIndex = min(currentIndex + 2, chapters.index(before: chapters.endIndex))
        var ranges: [Range<TimeInterval>] = []

        ranges.append(clampedStart..<currentChapter.end)

        if currentIndex < forwardEndIndex {
            for index in chapters.index(after: currentIndex)...forwardEndIndex {
                ranges.append(chapters[index].start..<chapters[index].end)
            }
        }

        if currentChapter.start < clampedStart {
            ranges.append(currentChapter.start..<clampedStart)
        }

        if chapters.index(after: forwardEndIndex) < chapters.endIndex {
            for index in chapters.index(after: forwardEndIndex)..<chapters.endIndex {
                ranges.append(chapters[index].start..<chapters[index].end)
            }
        }

        if currentIndex > chapters.startIndex {
            for index in chapters.startIndex..<currentIndex {
                ranges.append(chapters[index].start..<chapters[index].end)
            }
        }

        return ranges.flatMap { jobs(in: $0, tracks: tracks) }
    }

    private func jobs(in range: Range<TimeInterval>, tracks: [AudioTrackInfo]) -> [TranscriptionJob] {
        guard range.upperBound - range.lowerBound > 0.5 else { return [] }

        return tracks.compactMap { track in
            let start = max(range.lowerBound, track.startOffset)
            let end = min(range.upperBound, track.endOffset)
            guard end - start > 0.5 else { return nil }
            return TranscriptionJob(
                track: track,
                startTime: start,
                endTime: end,
                label: "\(formatTime(start))-\(formatTime(end))"
            )
        }
    }

    private func mergeSegments(_ existing: [TranscriptSegment], _ newSegments: [TranscriptSegment]) -> [TranscriptSegment] {
        TranscriptSegmentNormalizer.normalize(existing + newSegments)
    }

    private func normalizedChapters(for book: Book, duration: TimeInterval) -> [Chapter] {
        guard let chapters = book.chapters, !chapters.isEmpty else { return [] }
        let sorted = chapters.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.end < rhs.end }
            return lhs.start < rhs.start
        }

        return sorted.enumerated().map { index, chapter in
            let start = max(chapter.start, 0)
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

    private func assignChapters(segments: [TranscriptSegment], chapters: [Chapter]) -> [TranscriptSegment] {
        guard !chapters.isEmpty else { return segments }
        return segments.map { segment in
            let chapter =
                chapters.first { $0.start <= segment.startTime && segment.startTime < $0.end }
                ?? chapters.last { $0.start <= segment.startTime }
            return TranscriptSegment(
                id: segment.id,
                bookStableId: segment.bookStableId,
                chapterId: chapter?.id,
                trackIndex: segment.trackIndex,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                confidence: segment.confidence,
                isFinal: segment.isFinal
            )
        }
    }

    #if os(iOS)
    @available(iOS 26.0, *)
    private func supportedLocale(for book: Book) async throws -> Locale {
        let status = await Self.requestSpeechAuthorization()
        guard status == .authorized else {
            throw AudiobookTranscriptionError.speechAuthorizationDenied
        }

        guard SpeechTranscriber.isAvailable else {
            throw AudiobookTranscriptionError.speechTranscriberUnavailable
        }

        let requested = Locale(identifier: (book.language?.isEmpty == false ? book.language : nil) ?? Locale.current.identifier)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw AudiobookTranscriptionError.localeUnsupported
        }
        return supported
    }

    @available(iOS 26.0, *)
    private func transcribeTrack(_ job: TranscriptionJob, book: Book, locale: Locale) async throws -> [TranscriptSegment] {
        guard let url = URL(string: job.track.contentUrl), url.isFileURL else {
            throw AudiobookTranscriptionError.invalidTrackURL
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        try await ensureAssetsInstalled(for: transcriber)

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .utility, modelRetention: .whileInUse)
        )

        let bookStableId = book.stableId
        let trackIndex = job.track.index
        let jobStart = job.startTime
        let jobEnd = job.endTime

        let resultTask = Task.detached { () throws -> [TranscriptSegment] in
            var collected: [TranscriptSegment] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let globalStart = max(jobStart, CMTimeGetSeconds(result.range.start))
                let duration = max(0.1, CMTimeGetSeconds(result.range.duration))
                let globalEnd = min(jobEnd, globalStart + duration)
                guard globalEnd > jobStart, globalStart < jobEnd else { continue }
                let id = "\(bookStableId)|\(trackIndex)|\(String(format: "%.3f", globalStart))"

                let segment = TranscriptSegment(
                    id: id,
                    bookStableId: bookStableId,
                    chapterId: nil,
                    trackIndex: trackIndex,
                    startTime: globalStart,
                    endTime: max(globalEnd, globalStart + 0.1),
                    text: text,
                    confidence: nil,
                    isFinal: true
                )
                collected.append(segment)
            }
            return collected
        }

        do {
            let input = AudioFileAnalyzerInputSequence(
                url: url,
                trackStartOffset: job.track.startOffset,
                startTime: job.startTime,
                endTime: job.endTime
            )
            let lastSampleTime = try await analyzer.analyzeSequence(input)
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await resultTask.value
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    @available(iOS 26.0, *)
    private func ensureAssetsInstalled(for transcriber: SpeechTranscriber) async throws {
        let modules: [any SpeechModule] = [transcriber]
        let status = await AssetInventory.status(forModules: modules)
        switch status {
        case .installed:
            return
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                throw AudiobookTranscriptionError.assetUnavailable
            }
            try await request.downloadAndInstall()
            guard await AssetInventory.status(forModules: modules) == .installed else {
                throw AudiobookTranscriptionError.assetUnavailable
            }
        case .unsupported:
            throw AudiobookTranscriptionError.assetUnavailable
        @unknown default:
            throw AudiobookTranscriptionError.assetUnavailable
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
    #endif

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

private struct TranscriptionJob {
    let track: AudioTrackInfo
    let startTime: TimeInterval
    let endTime: TimeInterval
    let label: String
}

#if os(iOS)
@available(iOS 26.0, *)
nonisolated private struct AudioFileAnalyzerInputSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    private static let speechSampleRate: Double = 16_000
    private static let speechTimescale = CMTimeScale(16_000)

    let url: URL
    let trackStartOffset: TimeInterval
    let startTime: TimeInterval
    let endTime: TimeInterval
    let bufferFrameCapacity: AVAudioFrameCount = 16_384

    func makeAsyncIterator() -> Iterator {
        Iterator(
            url: url,
            trackStartOffset: trackStartOffset,
            startTime: startTime,
            endTime: endTime,
            bufferFrameCapacity: bufferFrameCapacity
        )
    }

    struct Iterator: AsyncIteratorProtocol {
        let url: URL
        let trackStartOffset: TimeInterval
        let startTime: TimeInterval
        let endTime: TimeInterval
        let bufferFrameCapacity: AVAudioFrameCount

        private var audioFile: AVAudioFile?
        private var converter: AVAudioConverter?
        private var outputFormat: AVAudioFormat?
        private var nextOutputTime: CMTime?
        private var currentFrame: AVAudioFramePosition = 0
        private var endFrame: AVAudioFramePosition = 0

        init(
            url: URL,
            trackStartOffset: TimeInterval,
            startTime: TimeInterval,
            endTime: TimeInterval,
            bufferFrameCapacity: AVAudioFrameCount
        ) {
            self.url = url
            self.trackStartOffset = trackStartOffset
            self.startTime = startTime
            self.endTime = endTime
            self.bufferFrameCapacity = bufferFrameCapacity
        }

        mutating func next() async throws -> AnalyzerInput? {
            while true {
                let file = try prepareFileIfNeeded()
                guard currentFrame < endFrame else { return nil }

                let framesToRead = Swift.min(bufferFrameCapacity, AVAudioFrameCount(endFrame - currentFrame))
                guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: framesToRead) else {
                    return nil
                }

                try file.read(into: sourceBuffer, frameCount: framesToRead)
                guard sourceBuffer.frameLength > 0 else { return nil }

                currentFrame += AVAudioFramePosition(sourceBuffer.frameLength)

                let convertedBuffer = try convert(sourceBuffer)
                guard convertedBuffer.frameLength > 0 else { continue }

                let bufferStartTime =
                    nextOutputTime ?? CMTime(seconds: startTime, preferredTimescale: AudioFileAnalyzerInputSequence.speechTimescale)
                nextOutputTime =
                    bufferStartTime
                    + CMTime(
                        value: CMTimeValue(convertedBuffer.frameLength),
                        timescale: AudioFileAnalyzerInputSequence.speechTimescale
                    )
                return AnalyzerInput(
                    buffer: convertedBuffer,
                    bufferStartTime: bufferStartTime
                )
            }
        }

        private mutating func prepareFileIfNeeded() throws -> AVAudioFile {
            if let audioFile {
                return audioFile
            }

            let file = try AVAudioFile(forReading: url)
            let speechFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: AudioFileAnalyzerInputSequence.speechSampleRate,
                channels: 1,
                interleaved: false
            )!
            converter = AVAudioConverter(from: file.processingFormat, to: speechFormat)
            outputFormat = speechFormat
            nextOutputTime = CMTime(seconds: startTime, preferredTimescale: AudioFileAnalyzerInputSequence.speechTimescale)

            let sampleRate = file.processingFormat.sampleRate
            let localStart = Swift.max(0, startTime - trackStartOffset)
            let localEnd = Swift.max(localStart, endTime - trackStartOffset)
            currentFrame = Swift.min(Swift.max(0, AVAudioFramePosition(localStart * sampleRate)), file.length)
            endFrame = Swift.min(Swift.max(currentFrame, AVAudioFramePosition(localEnd * sampleRate)), file.length)
            file.framePosition = currentFrame
            audioFile = file
            return file
        }

        private mutating func convert(_ sourceBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
            guard let converter, let outputFormat else {
                return sourceBuffer
            }

            let ratio = outputFormat.sampleRate / sourceBuffer.format.sampleRate
            let outputCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 256
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                return sourceBuffer
            }

            let inputState = AudioConverterInputState(buffer: sourceBuffer)
            var conversionError: NSError?
            converter.convert(to: outputBuffer, error: &conversionError) { _, status in
                if inputState.didProvideInput {
                    status.pointee = .noDataNow
                    return nil
                }

                inputState.didProvideInput = true
                status.pointee = .haveData
                return inputState.buffer
            }

            if let conversionError {
                throw conversionError
            }

            return outputBuffer
        }
    }
}
#endif

nonisolated private final class AudioConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
