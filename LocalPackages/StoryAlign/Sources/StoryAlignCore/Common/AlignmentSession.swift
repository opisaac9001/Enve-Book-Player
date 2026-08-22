//
// session.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//

import Foundation

/// A single alignment run.
///
/// `AlignmentSession` bundles up the request (input files + session directory), the configuration knobs,
/// logging, and progress tracking. It also owns cleanup of the session directory when the run completes.
///
/// In most cases, you create one session, run one alignment, then call `cleanup()`.
///
public final class AlignmentSession : Sendable {
    public let request: AlignmentRequest
    public let config: AlignmentConfig
    public let logger: Logger
    public let transcriberFactory:TranscriberFactory
    public let transcriptionStore:TranscriptionStore?
    
    internal let progressTracker: ProgressTracker

    
    /// Create a new session.
    ///
    /// - Parameters:
    ///   - request: Input URLs and session directory info.
    ///   - config: Configuration knobs for the run.
    ///   - logger: Logger used for warnings/errors and any debug output. Use StderrLogger() for simple logging
    ///   - transcriberFactory: Provides transcriber instances.
    ///   - transcriptionStore: Optional hook for caching/storing transcriptions for later reuse.
    ///
    public init(request: AlignmentRequest, config: AlignmentConfig, logger: Logger = NullLogger(), transcriberFactory:TranscriberFactory, transcriptionStore:TranscriptionStore? = nil ) {
        self.request = request
        self.config = config
        self.logger = logger
        self.progressTracker = Self.buildProgressTracker(config: config, logger: logger)
        self.transcriberFactory = transcriberFactory
        self.transcriptionStore = transcriptionStore
    }

    /// Finish progress tracking and remove the session directory if this session created it.
    ///
    /// If the caller provided `sessionDir` when building the request, `cleanup()` will leave it alone.
    /// That leaves everything extracted and created in the sessionDir. That can be useful for debugging,
    /// but it can add clutter quickly in other cases. If the library created a temp directory, `
    /// cleanup()` will remove it.
    ///
    public func cleanup() {
        progressTracker.finish()
        if !request.shouldRemoveSessionDir {
            return
        }
        try? FileManager.default.removeItem(at: request.sessionDir)
    }
    
    /// Convenience initializer for using Apple's SpeechTranscriber for transcription.
    public convenience init(request: AlignmentRequest, config: AlignmentConfig, logger: Logger = NullLogger(), speechAnalyzerConfig:SpeechAnalyzerConfig, transcriptionStore:TranscriptionStore? = nil  ) {
        self.init(request: request, config: config, logger: logger, transcriberFactory: SpeechAnalyzerTranscriberFactory(speechAnalyzerConfig: speechAnalyzerConfig))
    }
}

///
/// Functions for adding and removing ProgresListeners to which progress is reported
/// as the process is run
///
public extension AlignmentSession {
    @discardableResult func addProgressListener( _ listener:ProgressListener ) -> Int {
        return progressTracker.addListener(listener)
    }

    func removeProgressListener( handle:Int ) {
        progressTracker.removeListener(handle: handle)
    }
}


///////////

private extension AlignmentSession {
    private static func buildProgressTracker(config:AlignmentConfig, logger:Logger) -> ProgressTracker {
        let alignmentStageUnit:ProgressUnit = config.granularity == .phrase ? .phrases : .sentences
        let plannedProgressStages = ProgressStage.orderedCases.filter { stage in
            if stage == .alignWords {
                return config.granularity.useWordTokenizer
            }
            if stage == .report {
                return config.reportType != .none
            }
            return true
        }
        return ProgressTracker(plannedStages: plannedProgressStages, alignmentStageUnit: alignmentStageUnit, logger: logger)
    }
}


////////////////////////////////////////
// MARK: AlignmentRequest
//

/// The inputs and working directory for an alignment run.
///
/// `AlignmentRequest` includes the ebook, one or more audiobook URLs, and a session directory used for
/// intermediate files and persisted stage outputs.
///
/// Notes: Only a single audiobook URL is supported at this time. All others will be ignored
///
public struct AlignmentRequest : Sendable {
    public let epubURL:URL
    public let audioBookURLs:[URL]
    public let sessionDir: URL
    let shouldRemoveSessionDir: Bool

    /// Create a request.
    ///
    /// - Parameters:
    ///   - epubURL: Input EPUB.
    ///   - audioBookURLs: One or more audiobook URLs.
    ///   - sessionDir: Temporary storage location. Useful for debugging, but should be left nil in most cases
    ///
    /// - Throws: If the temp session directory cannot be created.
    ///
    public init(epubURL:URL, audioBookURLs:[URL], sessionDir: String? = nil) throws {
        self.epubURL = epubURL
        self.audioBookURLs = audioBookURLs
        
        self.sessionDir = try {
            if let sessionDir {
                return URL(fileURLWithPath: sessionDir)
            }
            let tempDir = FileManager.default.temporaryDirectory
            let sessionDir = tempDir.appendingPathComponent("story_align_\(UUID().uuidString.prefix(12))", isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            return sessionDir
        }()
        self.shouldRemoveSessionDir = (sessionDir == nil)
    }
}


////////////////////////////////////////
// MARK: AlignmentConfig
//

/// Configuration knobs for a session.
///
/// This mirrors the important runtime flags from the CLI: model selection, audio loader, throttling,
/// report selection, chapter range, and highlight granularity. Defaults are chosen to match the CLI and what seems to work
/// best in practice.
///
///
public struct AlignmentConfig : Sendable,Codable {
    public let audioLoaderType:AudioLoaderType
    public let concurrency:Int
    public let contributors:[String]
    public let reportType:ReportType
    public let startManifestItemId:String?
    public let endManifestItemId:String?
    public let granularity:Granularity
    public let granularityExpansion:GranularityExpansion?
    
    /// Create a config.
    ///
    /// - Parameters:
    ///   - audioLoaderType: Audio backend (defaults to Apple frameworks).
    ///   - concurrency: # concurrent tasks when transcribing, aligning, ... Defaults to processor count
    ///   - reportType: Whether to produce an alignment report and level of detail therein (defaults to `.none`).
    ///   - startChapter: Optional start chapter (manifest item id). -- can improve performance & resuls
    ///   - endChapter: Optional end chapter (manifest item id). -- can improve performance & resuls
    ///   - granularity: Highlight granularity (defaults to sentence).
    ///   - granularityExpansion: use nested tags to expand active text rather than replace it
    ///   - extraContributors: Additional contributor strings for produced epub.
    ///
    public init(
        audioLoaderType:AudioLoaderType = .avfoundation,
        concurrency:Int=0,
        reportType:ReportType = .none,
        startChapter:String? = nil,
        endChapter:String? = nil,
        granularity:Granularity = .sentence,
        granularityExpansion:GranularityExpansion? = nil,
        extraContributors:[String] = [],
    ) {
        self.audioLoaderType = audioLoaderType
        self.concurrency = concurrency
        self.reportType = reportType
        self.startManifestItemId = startChapter
        self.endManifestItemId = endChapter
        self.granularity = granularity
        self.granularityExpansion = granularityExpansion

        self.contributors = {
            let coreVersion = StoryAlignVersion()
            let coreContributor = "\(coreVersion.toolName) v\(coreVersion.shortVersionStr)"
            if extraContributors.isEmpty {
                return [coreContributor]
            }
            let storyalignCli = "storyalign"
            if extraContributors.first!.hasPrefix(storyalignCli) == true {
                return extraContributors
            }
            
            return [coreContributor] + extraContributors
        }()
    }
}



/// A small convenience protocol for anything that already has an `AlignmentSession`.
///
/// Most of the core pipeline types hold onto a session. Conforming to this protocol lets them share
/// common helpers like `logger` and `progressTracker` without threading those dependencies everywhere.
public protocol AlignmentSessionProviding   {
    var session:AlignmentSession { get }
}
extension AlignmentSessionProviding {
    var logger:Logger { session.logger }
    var progressTracker:ProgressTracker { session.progressTracker }
    var sessionConfig:AlignmentConfig { session.config }
}
