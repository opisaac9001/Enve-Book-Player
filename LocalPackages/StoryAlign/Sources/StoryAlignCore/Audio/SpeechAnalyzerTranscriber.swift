//
// SpeechAnalyzerTranscriber
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//
//  Created by Rich Waters on 2/18/26.
//

import Foundation
import Speech

fileprivate final class ActiveRequestsCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.withLock { count += 1; return count } }
    func decrement() -> Int { lock.withLock { count -= 1; return count } }
}
fileprivate let activeRequestsCounter = ActiveRequestsCounter()

public enum SpeechAnalyzerBias: String, Codable, OrderedCaseIterable,Sendable {
    case fast
    case standard
    
    public static let orderedCases: [SpeechAnalyzerBias] = [.fast, .standard ]
}

///   - bias: bias transcription towards speed vs. accuracy
///   - localeId: language tag or locale identifier for transcription
///   
public struct SpeechAnalyzerConfig :  TranscriberConfig {
    public let bias:SpeechAnalyzerBias
    public let localeId:String?
    
    public init(bias: SpeechAnalyzerBias = .fast, localeId: String? = nil ) {
        self.bias = bias
        self.localeId = localeId
    }
    
    public var sha256:String {
        [
            "bias" : bias.rawValue,
            "localeId" : localeId ?? ""
        ].sha256
    }
    
    public var formattedConfig: String {
        return "{ bias: \(bias), localeId: \(localeId ?? "") ) }"
    }
}


public struct SpeechAnalyzerTranscriberFactory : TranscriberFactory {
    public let speechAnalyzerConfig:SpeechAnalyzerConfig
    public init(speechAnalyzerConfig: SpeechAnalyzerConfig) {
        self.speechAnalyzerConfig = speechAnalyzerConfig
    }
    
    public func transcriber( session:AlignmentSession ) throws -> Transcriber {
        if #available(iOS 26.0, macOS 26.0, *) {
            return SpeechAnalyzerTranscriber(session: session, speechAnalyzerConfig: speechAnalyzerConfig)
        }
        throw StoryAlignError("Speech Analyzer requires iOS 26 or macOS 26")
    }
}



/// transcriber that uses Apple's SpeechAnalyzer framework
///
@available(iOS 26.0, macOS 26.0, *)
public struct SpeechAnalyzerTranscriber : AlignmentSessionProviding, Transcriber {
    public let session:AlignmentSession
    public let identifier = "speechanalyzer"
    public var config:TranscriberConfig { speechAnalyzerConfig }
    public let speechAnalyzerConfig:SpeechAnalyzerConfig
    
    public static func normalizedLocaleId(_ localeId:String) -> String {
        localeId.replacing("-", with: "_" )
    }

    public func transcribe( epub:EpubDocument, audioFile:AudioFile, pcmSamples:[Float32] ) async throws -> RawTranscription {
        while true {
            do {
                return try await transcribeOnce(epub: epub, audioFile: audioFile, pcmSamples: pcmSamples)
            }
            catch let err {
                let nsError = err as NSError
                if nsError.domain != "SFSpeechErrorDomain" || nsError.code != 16 {
                    throw err
                }
                logger.log(.info, "SpeechAnalyzer limit reached; waiting to retry")
                try await Task.sleep(for: .seconds(60))
            }
        }
    }


    public func transcribeOnce( epub:EpubDocument, audioFile:AudioFile, pcmSamples:[Float32] ) async throws -> RawTranscription {
        let sha256 = pcmSamples.sha256.prefix(8)
        let transcriber = try await buildTranscriber(for:epub)

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw StoryAlignError("On-device speech model unavailable: SpeechAnalyzer returned no compatible audio format for this locale. The speech model for the transcription language may not be installed.")
        }
        logger.log(.info, "SpeechAnalyzer input format: \(Int(analyzerFormat.sampleRate))Hz \(analyzerFormat.channelCount)ch common=\(analyzerFormat.commonFormat.rawValue) + \(sha256)")

        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioLoaderPCM.sampleRate,
            channels: AVAudioChannelCount(AudioLoaderPCM.channels),
            interleaved: false
        )!
        let inputConverter = analyzerFormat == sourceFormat ? nil : AVAudioConverter(from: sourceFormat, to: analyzerFormat)

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)

        let activeRequestsCount = activeRequestsCounter.increment()
        logger.log(.info, "SpeechAnalyzer active requests: \(activeRequestsCount) + \(sha256)")
        defer {
            let activeRequestsCount = activeRequestsCounter.decrement()
            logger.log(.info, "SpeechAnalyzer active requests: \(activeRequestsCount) - \(sha256)")
        }

        let resultsTask = Task<[TranscriptionSegment], Error> {
            var rawSegments: [TranscriptionSegment] = []

            for try await result in transcriber.results {
                try Task.checkCancellation()

                guard result.isFinal else {
                    continue
                }

                let tokens = transcriptionTokens(from: result.text)
                let start = result.range.start.seconds
                let end = start + result.range.duration.seconds
                let text = String(result.text.characters)
                let segment = TranscriptionSegment(text: text, start: start, end: end, audioFile: audioFile, tokens: tokens)

                progressTracker.updateProgress(for: .transcribe, event:.update, increment: segment.duration)

                rawSegments.append(segment)
            }
            return rawSegments
        }

        do {
            try await withTaskCancellationHandler {

                let frameSize = 8192 * AudioLoaderPCM.channels
                var i = 0

                while i < pcmSamples.count {
                    try Task.checkCancellation()

                    let end = min(i + frameSize, pcmSamples.count)
                    let frame = Array(pcmSamples[i..<end])
                    let buf = try analyzerBuffer(from: frame, sourceFormat: sourceFormat, analyzerFormat: analyzerFormat, converter: inputConverter)
                    cont.yield(AnalyzerInput(buffer: buf))

                    i = end
                }
                cont.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            onCancel: {
                cont.finish()
                resultsTask.cancel()
                Task {
                    await analyzer.cancelAndFinishNow()
                }
            }
        } catch is CancellationError {
            cont.finish()
            resultsTask.cancel()
            throw CancellationError()
        } catch {
            cont.finish()
            resultsTask.cancel()
            throw error
        }

        try Task.checkCancellation()

        let rawSegments = try await resultsTask.value
        logger.log(.info, "SpeechAnalyzer produced \(rawSegments.count) final segment(s) + \(sha256)")

        let segStr = rawSegments.map { "\($0.start) to \($0.end): \($0.text)" }.joined(separator: "\n")
        logger.log(.debug, "Segments: \(segStr)" )

        let rawTranscription = RawTranscription(segments: rawSegments)

        return rawTranscription
    }

    public func warmupModel( epub:EpubDocument, audioBook:AudioBook ) async throws {
        let locale = try await locale(for: epub)
        progressTracker.updateProgress(for: .model, event: .start, item:locale.identifier)
        
        _ = try await buildTranscriber(for:epub, ensureAssets: true)
        if let lang = epub.metaInfo.language {
            let normalizedLocaleId = Self.normalizedLocaleId(locale.identifier)
            let normalizedLang = Self.normalizedLocaleId(lang)
            if normalizedLocaleId.lowercased().starts(with: normalizedLang.lowercased()) == false {
                logger.log( .warn, "Possible mismatch between epub language:\(lang) and speechanalyzer locale: \(locale.identifier).")
            }
        }
        
        progressTracker.updateProgress(for: .model, event: .end, item:locale.identifier )
    }
}


@available(iOS 26.0, macOS 26.0, *)
extension SpeechAnalyzerTranscriber {

    func buildTranscriber( for epub:EpubDocument, ensureAssets:Bool = false ) async throws -> SpeechTranscriber {
        let locale = try await locale(for: epub)
        logger.log(.info, "SpeechAnalyzer locale: \(locale.identifier) (epub language: \(epub.metaInfo.language ?? "nil"), ensureAssets: \(ensureAssets))")

        let reportingOptions:Set<SpeechTranscriber.ReportingOption> = speechAnalyzerConfig.bias == .fast ? [.fastResults] : []
        
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reportingOptions,
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        if ensureAssets {
            let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
            let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
            logger.log(.info, "SpeechTranscriber locales — installed: \(installed), supported count: \(supported.count)")
            if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                logger.log(.info, "Installing speech assets for \(locale.identifier(.bcp47))…")
                try await installationRequest.downloadAndInstall()
                logger.log(.info, "Speech asset install complete for \(locale.identifier(.bcp47))")
            } else {
                logger.log(.info, "Speech assets already present for \(locale.identifier(.bcp47))")
            }
        }

        return transcriber
    }
    
    func locale( for epub:EpubDocument ) async throws -> Locale {
        if let localeId = speechAnalyzerConfig.localeId {
            let locale = Locale(identifier: localeId)
            if await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil {
                return locale
            }
            let normalizedLocale =  Locale(identifier:Self.normalizedLocaleId(localeId))
            if await SpeechTranscriber.supportedLocale(equivalentTo: normalizedLocale) != nil {
                return normalizedLocale
            }
            logger.log( .warn,  "Locale \(localeId) not supported. Trying current locale.")
        }
        
        if let bookLang = epub.metaInfo.language {
            for lang in Locale.preferredLanguages {
                if lang.starts(with: bookLang) {
                    if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: lang)) {
                        return locale
                    }
                }
            }
        }
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return locale
        }
        logger.log( .warn,  "No suitable locale found. Defaulting to en_US.")
        return Locale(identifier: "en_US")
    }
    
    func transcriptionTokens( from attributed: AttributedString) -> [TranscriptionToken] {
        let tokens:[TranscriptionToken] = attributed.runs.compactMap { run in
            let slice = attributed[run.range]
            let text = String(slice.characters)
            let start = run.audioTimeRange?.start.seconds ?? 0.0
            let end = run.audioTimeRange?.end.seconds ?? 0.0
            let confidence = run.transcriptionConfidence ?? 0.0
            let token = TranscriptionToken(text: text, start: start, end: end, voiceLen: -1, dtw: -1, timeConfidence:confidence, textConfidence: confidence)
            
            return token
        }

        return tokens
    }
    
    /// Builds a buffer of `samples` (16 kHz mono float32) in the exact format `SpeechAnalyzer`
    /// requested via `bestAvailableAudioFormat`. Feeding audio in any other sample rate/channel
    /// layout makes the analyzer emit zero final results, so the conversion is mandatory when the
    /// analyzer's format differs from the loader's 16 kHz mono float32 output.
    func analyzerBuffer(
        from samples: [Float],
        sourceFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        converter: AVAudioConverter?
    ) throws -> AVAudioPCMBuffer {
        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw StoryAlignError("Error creating input buffer for pcm samples")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        _ = samples.withUnsafeBufferPointer { src in
            memcpy(input.floatChannelData![0], src.baseAddress!, samples.count * MemoryLayout<Float>.size)
        }

        guard let converter else { return input }

        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            throw StoryAlignError("Error creating analyzer input buffer")
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inStatus in
            if consumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inStatus.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        if status == .error {
            throw StoryAlignError("Audio conversion to the analyzer format failed")
        }
        return output
    }
}
