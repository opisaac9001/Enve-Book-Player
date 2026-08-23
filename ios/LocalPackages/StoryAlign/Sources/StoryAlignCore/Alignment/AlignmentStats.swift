//
// AlignmentStats.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters


import Foundation

public enum ReportType: String , OrderedCaseIterable, Codable, Sendable {
    case none
    case score
    case stats
    case full
    case json
    
    public static let orderedCases: [ReportType] = [.none, .score, .stats, .full, .json]
}

func zip3<A, B, C>(_ a: [A], _ b: [B], _ c: [C]) -> [(A, B, C)] {
    zip(a, zip(b, c)).map { ($0, $1.0, $1.1) }
}


struct ChapterReport:Codable {
    let chapterId:String
    let chapterName:String
    let sentences:[ReportSentence]
    
    struct ReportSentence : Codable {
        let chapterSentenceId:Int
        let chapterSentence:String
        let transcriptionSentence:String
        let duration:Double
        let pace:Double
        let zscore:Double?
    }
}
struct ChapterSentences:Codable {
    let chapterName:String
    let sentences:[String]
}





public struct AlignmentStats : Codable {
    var chapterSentenceCount:Int = 0
    var wordCount:Int = 0
    var exactMatches:Int = 0
    var trimmedLeadingMatches:Int = 0
    var matchesIgnoringEndsPunctuation:Int = 0
    var matchesIgnoringAllPunctuation:Int = 0
    var nearMatchs:Int = 0
    var interpolated:Int = 0
    var recoverable:Int = 0
    var skipped:Int = 0
    var missedChapters:Int = 0
    var missedChapterSentences:Int = 0
    var smilSpans:Int = 0
    
    var examined : Int {
        chapterSentenceCount
    }
    var succeeded: Int {
        exactMatches + matchesIgnoringEndsPunctuation + matchesIgnoringAllPunctuation + nearMatchs + trimmedLeadingMatches
    }
    var missed: Int {
        interpolated + recoverable + missedChapterSentences
    }
    var percentSuccess: Double {
        (Double(succeeded)/Double(examined) * 100).roundToCs()
    }
    var percentMissed: Double {
        (Double(missed)/Double(examined) * 100).roundToCs()
    }
    
    func matchPercentStr(_ x:Int) -> String {
        let ratio = Double(x)/Double(succeeded)
        let percent = (ratio*100).roundToCs()
        return String(percent)+"%"
    }
    
    public init() {
    }
    
    init( alignedChapter:AlignedChapter ) {
        self.init()
        
        let chapterSentences = alignedChapter.manifestItem.xhtmlSentences
        let skippedSentences = alignedChapter.skippedSentences
        let alignedSentences = alignedChapter.alignedSentences
                
        self.chapterSentenceCount = chapterSentences.count
        self.wordCount = alignedChapter.alignedSentencesWordCount
        self.skipped = skippedSentences.count
        self.exactMatches = alignedSentences.filter { $0.matchType == .exact }.count
        self.trimmedLeadingMatches = alignedSentences.filter { $0.matchType == .trimmedLeading }.count

        self.nearMatchs = alignedSentences.filter { $0.matchType == .nearest }.count
        self.interpolated = alignedSentences.filter { $0.matchType == .interpolated }.count
        self.recoverable = alignedSentences.filter { $0.matchType == .recoverable }.count
        self.matchesIgnoringEndsPunctuation = alignedSentences.filter { $0.matchType == .ignoringEndsPunctuation }.count
        self.matchesIgnoringAllPunctuation = alignedSentences.filter { $0.matchType == .ignoringAllPunctuation }.count

        self.missedChapters = alignedChapter.isMissingChapter ? 1 : 0
        self.missedChapterSentences = alignedChapter.isMissingChapter ? alignedChapter.missingSentences.count : 0
        self.smilSpans = alignedChapter.alignedWords.isEmpty ? alignedChapter.alignedSentences.count : alignedChapter.alignedWords.count
    }
    
    static public func + (lhs: AlignmentStats, rhs: AlignmentStats) -> AlignmentStats {
        var result = AlignmentStats()
        result.chapterSentenceCount = lhs.chapterSentenceCount + rhs.chapterSentenceCount
        result.wordCount = lhs.wordCount + rhs.wordCount
        result.skipped =  lhs.skipped + rhs.skipped
        result.nearMatchs = lhs.nearMatchs + rhs.nearMatchs
        result.trimmedLeadingMatches = lhs.trimmedLeadingMatches + rhs.trimmedLeadingMatches
        result.exactMatches =  lhs.exactMatches + rhs.exactMatches
        result.matchesIgnoringEndsPunctuation = lhs.matchesIgnoringEndsPunctuation + rhs.matchesIgnoringEndsPunctuation
        result.matchesIgnoringAllPunctuation = lhs.matchesIgnoringAllPunctuation + rhs.matchesIgnoringAllPunctuation

        result.interpolated = lhs.interpolated + rhs.interpolated
        result.recoverable = lhs.recoverable + rhs.recoverable
        
        result.missedChapters = lhs.missedChapters + rhs.missedChapters
        result.missedChapterSentences = lhs.missedChapterSentences + rhs.missedChapterSentences
        result.smilSpans = lhs.smilSpans + rhs.smilSpans
        return result
    }
    static public func += (lhs: inout AlignmentStats, rhs: AlignmentStats) {
        lhs = lhs + rhs
    }

}

extension AlignmentStats : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        """
        Sentences: \(examined)
        Words:\(wordCount)
        Spans: \(smilSpans)
        Matched: \(succeeded) (\(percentSuccess)%)
        Missed: \(missed) (\(percentMissed)%)

        Matches:
            Exact: \(exactMatches) (\(matchPercentStr(exactMatches)))
            Trimmed leading: \(trimmedLeadingMatches)  (\(matchPercentStr(trimmedLeadingMatches)))
            Trimmed puncutation: \(matchesIgnoringEndsPunctuation)  (\(matchPercentStr(matchesIgnoringEndsPunctuation)))
            Removed punctuation: \(matchesIgnoringAllPunctuation)  (\(matchPercentStr(matchesIgnoringAllPunctuation)))
            Near: \(nearMatchs)  (\(matchPercentStr(nearMatchs)))
        
        Misses
            Unrecoverable:\(interpolated)
            Recoverable:\(recoverable)
            Entire Chapters: \(missedChapters)  (Sentences:\(missedChapterSentences))
        """
    }
    
    public var debugDescription: String {
        description
    }
    
}

public class AlignmentReportBuilder : AlignmentSessionProviding {
    let slowPaceThreshold:Double = 3.5
    let fastPaceThreshold:Double = 0.15
    public let session: AlignmentSession
    let alignedChapters:[AlignedChapter]
    let rawTranscriptions:[RawTranscription]
    
    lazy var allSentences:[AlignedSentence] = {
        alignedChapters.flatMap(\.alignedSentences)
    }()
    lazy var allInteriorSentences:[AlignedSentence] = {
        alignedChapters.flatMap { $0.interiorAlignedSentences }
    }()
    
    
    lazy var runtime:TimeInterval = {
        progressTracker.overallRunTime   // Not quite right, since it includes now
    }()
    
    
    public init( session:AlignmentSession, alignedChapters:[AlignedChapter], rawTranscriptions:[RawTranscription] ) {
        self.session = session
        self.alignedChapters = alignedChapters
        self.rawTranscriptions = rawTranscriptions
    }
    
    public func buildReport( session:AlignmentSession, epub:EpubDocument, audioBook:AudioBook  ) throws -> AlignmentReport {
        try Task.checkCancellation()

        progressTracker.updateProgress(for: .report, event: .start)
        
        //let toolTitle = "\(session.toolName ?? "") \(session.version ?? "")"
        let toolTitle = sessionConfig.contributors.first!
        
        let osVersion = {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            if v.patchVersion > 0 { return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" }
            return "macOS \(v.majorVersion).\(v.minorVersion)"
        }()
        
        let stageRunTimes = progressTracker.completedStageRunTimes.mapValues { $0.roundToMs()}
        
        let transcriber = try session.transcriberFactory.transcriber(session: session)

        let rpt = AlignmentReport(
            alignmentConfig:sessionConfig,
            toolTitle: toolTitle,
            osVersion: osVersion,
            epubURL: session.request.epubURL,
            audioURLs: session.request.audioBookURLs,
            audioBookDuration: audioBook.duration.roundToCs() ,
            Runtime: runtime.roundToMs(),
            Score: score,
            stageRunTimes: stageRunTimes,
            alignmentStats: alignmentStats,
            transcriberIdentifier: transcriber.identifier,
            transcriberConfig: transcriber.config.formattedConfig,
            transcriptionStats: trancriptionStats,
            rebuiltSentences: rebuiltSentences,
            fastPaceSentences: fastPaceSentences,
            slowPaceSentences: slowPaceSentences,
            shortDurationSentences: shortDurationSentences,
            longDurationSentences: longDurationSentences,
            missingChapterSentences: missingChapterSentences
        )
        progressTracker.updateProgress(for: .report, event: .end)

        return rpt
    }
    
    public var score:Double {
        //let allSentences = alignedChapters.flatMap(\.alignedSentences)
        //let totalSentences = alignedSentences.count + skippedSentences.count
        let totalWeight = alignedChapters.reduce(0) { $0 + ($1.manifestItem.xhtmlSentences.count) }
        if totalWeight <= 0 {
            return 0
        }
        
        let chapterScores:[(score:Double, sentenceCount:Double)] = alignedChapters.map {
            let score = score(forChapter: $0)
            let sentenceCount = Double( $0.manifestItem.xhtmlSentences.count )
            return ( score, sentenceCount )
        }
        
        let weightedSum = chapterScores.reduce(0) { $0 + $1.score * $1.sentenceCount }
        let combinedScore = weightedSum/Double(totalWeight)
        return combinedScore.roundToCs()
    }
    
    public var alignmentStats:AlignmentStats {
        let alignmentStats = alignedChapters.reduce(AlignmentStats()) { $0 + AlignmentStats(alignedChapter: $1) }
        return alignmentStats
    }
    
    public var trancriptionStats:TranscriptionStats {
        var transcriptionStats = rawTranscriptions.reduce(TranscriptionStats()) { $0 + TranscriptionStats(segments: $1.segments) }
        let medianPace = rawTranscriptions.flatMap { $0.segments }.map { $0.secondsPerWord }.median()
        transcriptionStats.medianPace = medianPace.roundToMs()
        transcriptionStats.averagePace = transcriptionStats.averagePace.roundToMs()
        transcriptionStats.avgSecsPerVoiceLen = transcriptionStats.avgSecsPerVoiceLen.roundToMs()
        return transcriptionStats
    }
    
    func chapterReport( from chapter:AlignedChapter, with zscoreTuples:[(AlignedSentence, Double?)] ) -> ChapterReport? {
        guard zscoreTuples.count > 0 else {
            return nil
        }
        let sentences = zscoreTuples.map { (alignedSentence, zscore) in
            let chapterSentence = ChapterReport.ReportSentence(
                chapterSentenceId: alignedSentence.sentenceId,
                chapterSentence: alignedSentence.xhtmlSentence,
                transcriptionSentence: alignedSentence.sentenceRange.sentenceText,
                duration: alignedSentence.sentenceRange.duration.roundToMs(),
                pace: alignedSentence.secondsPerWord.roundToMs(),
                zscore: zscore?.roundToMs()
            )
            return chapterSentence
        }
        return ChapterReport(
            chapterId: chapter.manifestItem.id,
            chapterName: chapter.manifestItem.name,
            sentences: sentences
        )
    }
    
    lazy var fastPaceSentences:[ChapterReport] = {
        let binSize = 12
        let threshold = -3.0
        
        let statsByBin = paceStatsByLength(sentences:allInteriorSentences, binSize: binSize)
        
        return alignedChapters.compactMap { chapter in
            let zscoreTuples = chapter.alignedSentences.compactMap { sentence -> (AlignedSentence, Double)? in
                let bin = sentence.xhtmlSentence.count / binSize
                guard let (med, mad) = statsByBin[bin] else { return nil }
                let mz = sentence.secondsPerChar.modifiedZcore( forMedian: med, medianAbsoluteDeviation: mad)
                guard mz < threshold else {
                    if sentence.secondsPerWord < fastPaceThreshold {
                        return (sentence, mz)
                    }
                    return nil
                }
                return (sentence, mz)
            }
            return chapterReport(from: chapter, with: zscoreTuples)
        }
    }()
    
    
    
    func paceStatsByLength(
        sentences: [AlignedSentence],
        binSize: Int
    ) -> [Int:(median: Double, mad: Double)] {
        let groups = Dictionary(grouping: sentences) {
            //let words = $0.chapterSentenceWords
            //return words.count/binSize
            //Int($0.chapterSentence.voiceLength) / binSize
            $0.xhtmlSentence.count / binSize
        }
        return groups.compactMapValues { bucket in
            //let paces = bucket.map { $0.secondsPerWord }
            let paces = bucket.map { $0.secondsPerChar }
            //let paces = bucket.map { $0.secondsPerVlen }
            let m = paces.median()
            let mad = paces.medianAbsoluteDeviation()
            guard  mad > 0 else { return nil }
            return (median: m, mad: mad)
        }
    }
    
    lazy var slowPaceSentences:[ChapterReport] = {
        let binSize = 12
        let threshold = 11.0
        
        let statsByBin = paceStatsByLength(sentences:allInteriorSentences, binSize: binSize)
        
        return alignedChapters.compactMap { chapter in
            let zscoreTuples = chapter.interiorAlignedSentences.compactMap { sentence -> (AlignedSentence, Double)? in
                let bin = sentence.xhtmlSentence.count / binSize
                guard let (med, mad) = statsByBin[bin] else { return nil }
                let mz = sentence.secondsPerChar.modifiedZcore(
                    forMedian: med,
                    medianAbsoluteDeviation: mad
                )
                guard mz > threshold else { return nil }
                return (sentence, mz)
            }
            return chapterReport(from: chapter, with: zscoreTuples)
        }
    }()
    
    
    lazy var longDurationSentences:[ChapterReport] = {
        let threshold = 11.0
        let durations = allInteriorSentences.map { $0.sentenceRange.duration }
        let median = durations.median()
        let mad = durations.medianAbsoluteDeviation()
        guard mad > 0 else {
            return []
        }
        
        let slowPacedChapSentenceIds = slowPaceChapterSentenceIds
        return alignedChapters.compactMap { chapter in
            let zscoreTuples = chapter.interiorAlignedSentences.compactMap { sentence -> (AlignedSentence, Double)? in
                if slowPacedChapSentenceIds.contains(where: { $0.chapterId == chapter.manifestItem.id && $0.sentenceId == sentence.sentenceId }) {
                    return nil
                }
                let mz = sentence.sentenceRange.duration.modifiedZcore( forMedian: median,  medianAbsoluteDeviation: mad )
                guard mz > threshold else {
                    return nil
                }
                return (sentence, mz)
            }
            return chapterReport(from: chapter, with: zscoreTuples)
        }
    }()
    
    /*
     public var shortDurationSentences:[AlignedSentence] {
     return alignedChapters.flatMap { alignedChapter in
     return alignedChapter.alignedSentences.filter { $0.sentenceRange.duration < 0.30 }
     }
     }
     
     */
    
    lazy var shortDurationSentences:[ChapterReport] = {
        let threshold = -1.5
        let durations = allInteriorSentences.map { $0.sentenceRange.duration }
        let median = durations.median()
        let mad = durations.medianAbsoluteDeviation()
        guard mad > 0 else {
            return []
        }
        
        let fastPacedChapSentenceIds = fastPaceChapterSentenceIds
        
        return alignedChapters.compactMap { chapter in
            let zscoreTuples = chapter.alignedSentences.compactMap { sentence -> (AlignedSentence, Double)? in
                if fastPacedChapSentenceIds.contains(where: { $0.chapterId == chapter.manifestItem.id && $0.sentenceId == sentence.sentenceId }) {
                    return nil
                }
                let mz = sentence.sentenceRange.duration.modifiedZcore( forMedian: median,  medianAbsoluteDeviation: mad )
                guard mz < threshold else {
                    if sentence.sentenceRange.duration < fastPaceThreshold {
                        return (sentence, mz)
                    }
                    return nil
                }
                return (sentence, mz)
            }
            return chapterReport(from: chapter, with: zscoreTuples)
        }
    }()
    
    lazy var fastPaceChapterSentenceIds:[(chapterId:String,sentenceId:Int)]  = {
        fastPaceSentences.flatMap { chapterReport in
            chapterReport.sentences.map { ( chapterId:chapterReport.chapterId, sentenceId:$0.chapterSentenceId) }
        }
    }()
    lazy var slowPaceChapterSentenceIds:[(chapterId:String,sentenceId:Int)] = {
        slowPaceSentences.flatMap { chapterReport in
            chapterReport.sentences.map { ( chapterId:chapterReport.chapterId, sentenceId:$0.chapterSentenceId) }
        }
    }()
    lazy var shortDurationChapterSentenceIds:[(chapterId:String,sentenceId:Int)] = {
        shortDurationSentences.flatMap { chapterReport in
            chapterReport.sentences.map { ( chapterId:chapterReport.chapterId, sentenceId:$0.chapterSentenceId) }
        }
    }()
    lazy var longDurationChapterSentenceIds:[(chapterId:String,sentenceId:Int)] = {
        longDurationSentences.flatMap { chapterReport in
            chapterReport.sentences.map { ( chapterId:chapterReport.chapterId, sentenceId:$0.chapterSentenceId) }
        }
    }()
    
    lazy var rebuiltSentences:[ChapterReport] = {
        return alignedChapters.compactMap {
            guard $0.rebuiltSentences.isEmpty == false else { return nil }
            let sentenceTuples = $0.rebuiltSentences.map { (sentence) -> (AlignedSentence,Double?) in
                (sentence, nil)
            }
            return chapterReport(from: $0, with: sentenceTuples)
        }
    }()
    
    lazy var missingChapterSentences:[ChapterSentences] = {
        let missingChapters = alignedChapters.filter { $0.isMissingChapter }
        let missingChapterSentences = missingChapters.map {
            ChapterSentences(chapterName: $0.manifestItem.name, sentences: $0.manifestItem.xhtmlSentences)
        }
        return missingChapterSentences
    }()
    

    
    func score( forChapter:AlignedChapter ) -> Double {
        if forChapter.alignedSentences.isEmpty {
            return 0.0
        }
        
        let totalSentences = (forChapter.manifestItem.xhtmlSentences.count)
        let skippedSentenceIds = Set( forChapter.skippedSentences.map { $0.chapterSentenceId } )
        let rebuiltSentenceIds = Set( forChapter.rebuiltSentences.map { $0.sentenceId } )
        let fastPaceSentenceIds = Set( fastPaceChapterSentenceIds.filter { $0.chapterId == forChapter.manifestItem.id }.map(\.sentenceId) )
        let slowPaceSentenceIds = Set( slowPaceChapterSentenceIds.filter { $0.chapterId == forChapter.manifestItem.id }.map(\.sentenceId) )
        let shortDurationSentenceIds = Set( shortDurationChapterSentenceIds.filter { $0.chapterId == forChapter.manifestItem.id }.map(\.sentenceId) )
        let longDurationSentenceIds = Set( longDurationChapterSentenceIds.filter { $0.chapterId == forChapter.manifestItem.id }.map(\.sentenceId) )
        
        var lastSentenceId = -1
        let weights:[Double] = forChapter.alignedSentences.map {
            if ($0.sentenceId - 1 ) != lastSentenceId {
                logger.log(.error, "Chapter missing sentence")
            }
            lastSentenceId = $0.sentenceId
            
            if fastPaceSentenceIds.contains($0.sentenceId) {
                return 0.0
            }
            if slowPaceSentenceIds.contains($0.sentenceId) {
                return 0.0
            }
            if shortDurationSentenceIds.contains($0.sentenceId) {
                return 0.1
            }
            if longDurationSentenceIds.contains( $0.sentenceId ) {
                return 0.3
            }
            if rebuiltSentenceIds.contains( $0.sentenceId ) {
                return 0.4
            }
            if $0.matchType == .interpolated {
                return 0.5
            }
            
            if $0.matchType == .recoverable {
                return 0.8
            }
            
            if skippedSentenceIds.contains( $0.sentenceId ) {
                // These are sentences that were initially skipped but then later aligned in between chapters
                return 0.9
            }
            
            
            return 1.0
        }
        
        let sumOfWeights = weights.reduce(0,+)
        let score = sumOfWeights/Double(totalSentences) * 100.0
        return score
    }
}


public struct AlignmentReport : Codable {
    let alignmentConfig:AlignmentConfig
    let toolTitle:String
    let osVersion:String
    let epubURL: URL
    let audioURLs: [URL]
    let audioBookDuration:TimeInterval
    let Runtime:TimeInterval  // Leave as capitalized to keep at top of
    let Score:Double          // Leave as capitalized to keep at top of
    let stageRunTimes:[ProgressStage:TimeInterval]
    let alignmentStats:AlignmentStats
    let transcriberIdentifier:String
    let transcriberConfig:String
    let transcriptionStats:TranscriptionStats
    let rebuiltSentences:[ChapterReport]
    let fastPaceSentences:[ChapterReport]
    let slowPaceSentences:[ChapterReport]
    let shortDurationSentences:[ChapterReport]
    let longDurationSentences:[ChapterReport]
    let missingChapterSentences:[ChapterSentences]
    
    public var score:Double { Score }
    public var runtime:TimeInterval { Runtime }

}


public struct TranscriptionStats : Codable {
    var segmentsCount: Int = 0
    var startGaps: Int = 0
    var endGaps: Int = 0
    var repaired:Int = 0
    var fastPaced:Int = 0
    var fastPaceThreshold = 0.15
    var averagePace:Double
    public var medianPace:Double
    var avgSecsPerVoiceLen:Double = 0
    
    public init(segmentsCount: Int=0, startGaps: Int=0, endGaps: Int=0, repaired: Int=0, fastPaced: Int=0, averagePace:Double=0, medianPace:Double=0) {
        self.segmentsCount = segmentsCount
        self.startGaps = startGaps
        self.endGaps = endGaps
        self.repaired = repaired
        self.fastPaced = fastPaced
        self.averagePace = averagePace
        self.medianPace = medianPace
    }
    
    init( segments:[TranscriptionSegment] ) {
        self.init()
        self.segmentsCount = segments.count
        self.startGaps  = segments.filter {  $0.startGap != 0 }.count
        self.endGaps  = segments.filter {  $0.endGap != 0 }.count
        self.repaired = segments.filter { $0.needsRepair }.count
        self.fastPaced = segments.filter { $0.isFastPaced }.count
        self.averagePace = segments.map { $0.secondsPerWord }.average()
        self.medianPace = segments.map { $0.secondsPerWord }.median()
        self.avgSecsPerVoiceLen = segments.map { $0.secondsPerVoiceLen }.average()
    }

    static public func + (lhs: TranscriptionStats, rhs: TranscriptionStats) -> TranscriptionStats {
        var result = TranscriptionStats()
        result.segmentsCount =  lhs.segmentsCount + rhs.segmentsCount
        result.startGaps = lhs.startGaps + rhs.startGaps
        result.endGaps = lhs.endGaps + rhs.endGaps
        result.repaired =  lhs.repaired + rhs.repaired
        result.fastPaced = lhs.fastPaced + rhs.fastPaced
        result.averagePace = (lhs.averagePace * Double(lhs.segmentsCount) + rhs.averagePace * Double(rhs.segmentsCount)) / ( Double(lhs.segmentsCount+rhs.segmentsCount ))
        result.medianPace = -1
        result.avgSecsPerVoiceLen = (lhs.avgSecsPerVoiceLen * Double(lhs.segmentsCount) + rhs.avgSecsPerVoiceLen * Double(rhs.segmentsCount)) / ( Double(lhs.segmentsCount+rhs.segmentsCount ))
        return result
    }
    static public func += (lhs: inout TranscriptionStats, rhs: TranscriptionStats) {
        lhs = lhs + rhs
    }
}
    
extension TranscriptionStats : CustomStringConvertible, CustomDebugStringConvertible {
    
    func percentStr(_ x:Int ) -> String {
        let ratio = Double(x)/Double(segmentsCount)
        let percent = (ratio*100).roundToCs()
        return String(percent)+"%"
    }
    
    public var description: String {
            """
            Segments: \(segmentsCount)
            Start gaps: \(startGaps) (\(percentStr(startGaps)))
            End gaps: \(endGaps) (\(percentStr( endGaps)))
            Repaired: \(repaired) (\(percentStr(repaired)))
            Too fast: \(fastPaced) (\(percentStr(fastPaced)))
            Average pace: \(averagePace.roundToCs()) seconds per word
            Average pace: \(avgSecsPerVoiceLen.roundToMs()) seconds per vlen
            Median pace: \(medianPace == -1 ? "N/A" : String(medianPace.roundToCs())) seconds per word
            """
    }
    
    public var debugDescription: String {
        description
    }
}
