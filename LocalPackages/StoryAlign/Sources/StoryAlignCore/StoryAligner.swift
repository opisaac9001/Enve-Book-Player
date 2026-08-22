//
//  StoryAligner.swift
//  StoryAlign
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//

import Foundation

/// storyalign’s main API for aligning ebooks & audiobook.
///
/// `StoryAligner` takes an `AlignmentSession` and runs the full pipeline:
/// parse the epub, parse/extract the audiobook, transcribe, align, write media overlays,
/// export the narrated epub, and optionally build a report.
///
///
public struct StoryAligner {
    public init() {}
    
    /// Align an ebook with an audiobook and produce a narrated epub.
    ///
    ///
    /// - Parameter session: The session describing the run: input URLs, the session directory, and config
    ///   such as report type and transcription settings.
    ///
    /// - Returns: The URL of the narrated epub, plus an optional report (depending on `session.config.reportType`).
    ///
    /// - Throws: Any error (including task cancellation) encountered while parsing, transcribing, aligning, updating the epub, exporting,
    ///   or building the report.
    ///
    ///
    public func alignStory( session:AlignmentSession ) async throws -> AlignmentResult {
        let epubURL = session.request.epubURL
        
        if let expansion = session.config.granularityExpansion, let scope = expansion.scope {
            if scope <= session.config.granularity {
                throw StoryAlignError("Granularity expansion \(expansion) is less than granularity:\(session.config.granularity)." )
            }
        }
        let epub = try await EpubParser(session: session).parse(url:epubURL)
        let audioBook = try await AudioFileProcessor(session: session).process(audioURLs: session.request.audioBookURLs, epub: epub)
        let transcriber = try session.transcriberFactory.transcriber(session: session)
        let transcriptions = try await transcriber.transcribe(epub:epub,  audioBook: audioBook )
        let alignedChapters = try await Aligner(session: session).align(ebook: epub, audioBook: audioBook, rawTranscriptions: transcriptions)
        try await EpubXmlUpdater(session: session).update(epub: epub, audioBook: audioBook, alignedChapters: alignedChapters )

        let narratedFileName = epubURL.deletingPathExtension().lastPathComponent+"_narrated.epub"
        let outputURL = session.request.sessionDir.appendingPathComponent(narratedFileName)
        try EpubExporter(session: session).export(eBook: epub, to: outputURL )

        if session.config.reportType == .none {
            return AlignmentResult(alignedEpubURL:outputURL, report:nil)
        }

        let reportBuilder = AlignmentReportBuilder(session: session, alignedChapters: alignedChapters, rawTranscriptions: transcriptions)
        let rpt = try reportBuilder.buildReport( session:session, epub: epub, audioBook: audioBook )

        return AlignmentResult(alignedEpubURL: outputURL, report: rpt)
    }
}

/// The result of an alignment run.
///
/// This always includes the output narrated epub URL. The report is
/// nil when`AlignmentSession.config.reportType == .none`.
///
public struct AlignmentResult {
    public let alignedEpubURL:URL
    public let report:AlignmentReport?
}
