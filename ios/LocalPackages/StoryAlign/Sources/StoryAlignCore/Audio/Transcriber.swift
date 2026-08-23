//
// Transcriber.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//

import Foundation

fileprivate let fastPaceThreshold = 0.15

public struct TranscriptionToken : Codable,Sendable, Equatable,Hashable {
    let text:String
    let start:TimeInterval
    let end:TimeInterval
    let voiceLen:Double
    let dtw:TimeInterval
    let timeConfidence:Double
    let textConfidence:Double
    
    func with(
           text: String? = nil,
           start: TimeInterval? = nil,
           end: TimeInterval? = nil,
           voiceLen: Double? = nil,
           dtw: TimeInterval? = nil,
           timeStampConfidence:Double? = nil,
           textConfidence:Double? = nil
       ) -> TranscriptionToken {
           let tt = TranscriptionToken(
               text:    text    ?? self.text,
               start:   start   ?? self.start,
               end:     end     ?? self.end,
               voiceLen: voiceLen ?? self.voiceLen,
               dtw:     dtw     ?? self.dtw,
               timeConfidence: timeStampConfidence ?? self.timeConfidence,
               textConfidence: textConfidence ?? self.textConfidence
           )
           return tt
       }
}
extension TranscriptionToken : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "\(text) Start: \(start) End: \(end) voiceLen:\(voiceLen) dtw:\(dtw)"
    }
    public var debugDescription: String {
        description
    }
}


public struct TranscriptionSegment:Codable,Sendable {
    var text:String
    var start:TimeInterval
    var end:TimeInterval
    let audioFile:AudioFile
    var tokens:[TranscriptionToken]
    var needsRepair:Bool=false
    
    func with(
           text: String? = nil,
           start: TimeInterval? = nil,
           end: TimeInterval? = nil,
           audioFile: AudioFile? = nil,
           tokens: [TranscriptionToken]? = nil
       ) -> TranscriptionSegment {
           TranscriptionSegment(
               text: text ?? self.text,
               start: start ?? self.start,
               end: end ?? self.end,
               audioFile: audioFile ?? self.audioFile,
               tokens: tokens ?? self.tokens
           )
       }
    
    var duration:Double { end - start }
    var tokenDuration : Double { (tokens.last?.end ?? end) - (tokens.first?.start ?? start)}
    var words:[String] { text.components(separatedBy: " ") }
    public var secondsPerWord:Double { duration / Double(words.count) }
    var isFastPaced:Bool { secondsPerWord < fastPaceThreshold }
    var endGap:Double { end - (tokens.last?.end ?? 0) }
    var startGap:Double { (tokens.first?.start ?? 0) - start}
    var voiceLen:Double {
        guard !tokens.isEmpty else { return text.voiceLength }
        return tokens.reduce(0) { $0 + $1.voiceLen }
    }
    var secondsPerVoiceLen:Double { duration/voiceLen }
}

extension TranscriptionSegment : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "\(text) Start: \(start) End: \(end) Duration: (\(duration)  secondsPerWord:\(secondsPerWord) startGap:\(startGap) endGap:\(endGap)  ) "
    }
    public var debugDescription: String {
        description
    }
}

public enum TokenTypeGuess:Int,Codable,Sendable {
    case whiteSpaceAndPunct
    case sentenceEnd
    case sentenceBegin
    case other
    case missing
    
}

public struct WordTimeStamp:Codable, Hashable,Sendable {
    let token: String
    let start: TimeInterval
    let end: TimeInterval
    let audioFile:AudioFile
    let transcriptionTokens:[TranscriptionToken]
    let segmentIndex:Int
    let tokenTypeGuess:TokenTypeGuess
    var index:Int = -1
    var startOffset: Int = -1
    var endOffset: Int = -1
    var isInterpolated:Bool = false
    var isRebuilt:Bool = false
    
    var origStart:TimeInterval {
        transcriptionTokens.first?.start ?? start
    }
    var origEnd:TimeInterval {
        transcriptionTokens.last?.end ?? end
    }
    var origDuration:TimeInterval {
        self.origEnd-self.origStart
    }
    
    var timeConfidence:Double {
        var weighted = 0.0
        var total = 0.0
        for transcriptionToken in transcriptionTokens {
            let c = transcriptionToken.timeConfidence
            let d = max(0, transcriptionToken.end - transcriptionToken.start)
            if d <= 0 { continue }
            weighted += c * d
            total += d
        }
        if total <= 0 { return  0.0 }
        return weighted / total
    }
    var textConfidence:Double {
        var weighted = 0.0
        var total = 0.0
        for transcriptionToken in transcriptionTokens {
            let c = transcriptionToken.textConfidence
            let d = max(0, transcriptionToken.end - transcriptionToken.start)
            if d <= 0 { continue }
            weighted += c * d
            total += d
        }
        if total <= 0 { return  0.0 }
        return weighted / total
    }
    
    var voiceLen:Double {
        guard !transcriptionTokens.isEmpty else { return token.voiceLength }
        return transcriptionTokens.reduce(0.0) { $0 + $1.voiceLen }
    }

    func with(
        token: String? = nil,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil,
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        audioFile: AudioFile? = nil,
        transcriptionTokens:[TranscriptionToken]? = nil,
        index: Int? = nil,
        segmentIndex: Int? = nil,
        tokenTypeGuess:TokenTypeGuess? = nil,
        isInterpolated:Bool? = nil,
        isRebuilt:Bool? = nil,

    ) -> WordTimeStamp {
        let ts = WordTimeStamp(            
            token: token ?? self.token,
            start: start ?? self.start,
            end: end ?? self.end,
            audioFile: audioFile ?? self.audioFile,
            transcriptionTokens: transcriptionTokens ?? self.transcriptionTokens,
            segmentIndex: segmentIndex ?? self.segmentIndex,
            tokenTypeGuess: tokenTypeGuess ?? self.tokenTypeGuess,
            index: index ?? self.index,
            startOffset: startOffset ?? self.startOffset,
            endOffset: endOffset ?? self.endOffset,
            isInterpolated: isInterpolated ?? self.isInterpolated,
            isRebuilt: isRebuilt ?? self.isRebuilt,
        )

        return ts
    }
    

    func merged(with other: WordTimeStamp) -> WordTimeStamp {
        let mergedStartOffset: Int
        if startOffset >= 0 && other.startOffset >= 0 {
            mergedStartOffset = min(startOffset, other.startOffset)
        } else if startOffset >= 0 {
            mergedStartOffset = startOffset
        } else if other.startOffset >= 0 {
            mergedStartOffset = other.startOffset
        } else {
            mergedStartOffset = -1
        }
        
        let mergedEndOffset: Int
        if endOffset >= 0 && other.endOffset >= 0 {
            mergedEndOffset = max(endOffset, other.endOffset)
        } else if endOffset >= 0 {
            mergedEndOffset = endOffset
        } else if other.endOffset >= 0 {
            mergedEndOffset = other.endOffset
        } else {
            mergedEndOffset = -1
        }
        
        let nuStamp = self.with(
            token: token + other.token,
            start: min(start, other.start),
            end: max(end, other.end),
            startOffset: mergedStartOffset,
            endOffset: mergedEndOffset,
            transcriptionTokens: self.transcriptionTokens + other.transcriptionTokens,
            isInterpolated: isInterpolated || other.isInterpolated,
            isRebuilt: isRebuilt || other.isRebuilt,
        )
        return nuStamp
    }
    
    var absoluteStart:TimeInterval {
        return audioFile.startTmeInterval + start
    }
    var absoluteEnd:TimeInterval {
        return audioFile.startTmeInterval + end
    }
    
    var duration:TimeInterval {
        (end - start).roundToMs()
    }
}

extension WordTimeStamp : CustomStringConvertible, CustomDebugStringConvertible {
    public var description : String {
        return "\(token): offsets:\(startOffset) -> \(endOffset), startTime:\(start), endTime:\(end)"
    }
    public var debugDescription: String {
        description
    }
}

extension [WordTimeStamp] {
    var debugDescription : String {
        return self.map { $0.debugDescription}.joined(separator: "\n")
    }
    
    var hasOverlaps : Bool {
        if self.isEmpty {
            return false
        }
        for i in 0..<self.count - 1 {
            if self[i].audioFile.filePath != self[i+1].audioFile.filePath {
                continue
            }
            if  self[i].end > self[i+1].start {
                return true
            }
        }
        return false
    }
    
    var hasEndBeforeStart:Bool {
        for i in 0..<self.count - 1 {
            if self[i].end < self[i].start {
                return true
            }
        }
        return false
    }
    
    func hasDuplicateConsecutiveSpans() -> Bool {
        guard count > 1 else { return false }
        let n = Swift.min(count,3)
        var hasDups = false
        for i in 0..<(count - n){
            let start = self[i].start
            let end = self[i].end
            let audioFile = self[i].audioFile
            for j in 1 ..< n  {
                if self[i+j].start != start || self[i+j].end != end  || self[i+j].audioFile.filePath != audioFile.filePath {
                    hasDups = false
                    break
                }
                hasDups = true
            }
            if hasDups {
                return true
            }
        }
        return hasDups
    }
}



public struct Transcription: Sendable {
    let transcription:String
    public let segments:[TranscriptionSegment]
    let wordTimeline: [WordTimeStamp]
    var sentences:[String] = []
    var sentencesOffsets:[Range<Int>] = []
    var offsetToIndexMap:[Int:String.Index] = [:]
    
    func indexOfSentence(containingOffset offset:Int) -> Int? {
        var low = 0
        var high = sentencesOffsets.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = sentencesOffsets[mid]
            if range.contains(offset) {
                return mid
            }
            if range.lowerBound < offset {
                low = mid + 1
                continue
            }
            
            high = mid - 1
        }
        return nil
    }
    
    func indexOfChar( atOffset:Int ) -> String.Index? {
        return offsetToIndexMap[atOffset]
    }
}

public struct RawTranscription:Codable, Sendable {
    public let segments:[TranscriptionSegment]
    
    var fastPacedSegments:[TranscriptionSegment] {
        segments.filter { $0.isFastPaced }
    }
}

public protocol TranscriberConfig : Sendable {
    var sha256:String { get }
    var formattedConfig:String { get }
}

public protocol Transcriber : Sendable, AlignmentSessionProviding {
    var identifier:String { get }
    var config:TranscriberConfig { get }
    func transcribe(epub:EpubDocument, audioFile:AudioFile) async throws -> RawTranscription
    func transcribe(epub:EpubDocument, audioFile:AudioFile, pcmSamples:[Float32]) async throws -> RawTranscription
    func buildTranscription( from rawTranscription:RawTranscription ) throws -> Transcription
    func warmupModel( epub:EpubDocument, audioBook:AudioBook) async throws
}


/// Important: the transcriberFactory is owned by AlignmentSession. Don't create a cycle by cache transcribers that own sessions.
public protocol TranscriberFactory : Sendable {
    func transcriber( session:AlignmentSession ) throws -> Transcriber
}

public extension Transcriber {

    func transcribe( epub:EpubDocument, audioBook:AudioBook ) async throws -> [RawTranscription] {
        try Task.checkCancellation()

        try await warmupModel( epub: epub, audioBook: audioBook)
        try Task.checkCancellation()
        
        progressTracker.updateProgress(for: .transcribe,event: .start, total: audioBook.duration)
        
        let nThreads = sessionConfig.concurrency
        let rawTranscriptions = try await audioBook.audioFiles.enumerated().asyncMap(concurrency: nThreads) { (index,audioFile) in
            //logger.log(.timestamp, "Transcribing \(index+1)/\(total)" )
            let rawTranscription = try await transcribe(epub:epub, audioFile: audioFile )
            //logger.log( .timestamp, "Complete transcription \(index+1)/\(total)" )
            return rawTranscription
        }
        progressTracker.updateProgress(for: .transcribe, event: .end)
        return rawTranscriptions
    }
    
    func transcribe(epub:EpubDocument, audioFile: AudioFile) async throws -> RawTranscription {
        let audioLoader = AudioLoaderFactory.audioLoader(for: session )
        logger.log(.debug, "\nBeginning decode of \(audioFile.filePath.lastPathComponent)" )
        let pcmSamples = try await audioLoader.decode(from: audioFile.filePath)
        logger.log( .debug, "Decode completed -- \(pcmSamples.count) samples, sha256: \(pcmSamples.sha256)")
        
        if let transcriptionStore = session.transcriptionStore {
            let transcriptionContext = TranscriptionStoreContext(audioFileName: audioFile.filePath.lastPathComponent, audioFileIndex: audioFile.index, pcmSamplesHash: pcmSamples.sha256, transcriberId: identifier, transcriberConfigHash: config.sha256)
            do {
                if let rawTranscription = try await transcriptionStore.fetch(using: transcriptionContext) {
                    progressTracker.updateProgress(for: .transcribe, event: .update, increment: audioFile.duration)
                    return rawTranscription
                }
            }
            catch let err {
                logger.log(.error, "Error while fetching stored transcription data: \(err)")
            }
            let rawTranscription = try await transcribe(epub: epub, audioFile: audioFile, pcmSamples: pcmSamples)
            if !rawTranscription.segments.isEmpty {
                do {
                    try await transcriptionStore.store(rawTranscription: rawTranscription, using: transcriptionContext)
                }
                catch let err {
                    logger.log(.error, "Error while persisting transcription: \(err)")
                }
            }
            return rawTranscription
        }
        
        return try await transcribe(epub: epub, audioFile: audioFile, pcmSamples: pcmSamples)
    }
}

public extension Transcription {
    static func concatTranscriptions(_ transcriptions: [Transcription], maxSentenceLen:Int? = nil, meanSentenceLen:Int? = nil  ) -> Transcription {
        var index = 0
        var offset = 0
        var fullTranscription = transcriptions.reduce( Transcription(transcription: "", segments: [], wordTimeline: []) ) { acc, current in
            let mergedTranscript = acc.transcription + current.transcription
            let segIndex = acc.segments.count
                        
            let adjustedTimeline = current.wordTimeline.map { entry in
                let timestamp = entry.with(startOffset:offset, endOffset:max( offset, offset + entry.token.count - 1), index:index, segmentIndex: entry.segmentIndex + segIndex)
                index += 1
                offset += entry.token.count
                return timestamp
            }
            let mergedSegments = acc.segments + current.segments
            
            let mergedTimeline = acc.wordTimeline + adjustedTimeline
            
            
            return Transcription(
                transcription: mergedTranscript,
                segments: mergedSegments,
                wordTimeline: mergedTimeline
            )
        }
        
        let longestSentenceLen = maxSentenceLen ?? NSInteger.max
        let avgSentenceLen = meanSentenceLen ?? 128
        
        let tokenizer = Tokenizer()

        fullTranscription.sentences = tokenizer.tokenizeSentences(text: fullTranscription.transcription)
            .flatMap { (sentence) -> [String] in
                if sentence.count < (longestSentenceLen) {
                    return [sentence]
                }
                let chunkedSentence = sentence.chunked(minLength: avgSentenceLen)
                return chunkedSentence
            }
        
        var offset2 = 0
        fullTranscription.sentencesOffsets = fullTranscription.sentences.map { (sentence) -> Range<Int> in
            let endOffset = offset2 + sentence.count
            let range = offset2..<endOffset
            offset2 = endOffset
            return range
        }

        fullTranscription.offsetToIndexMap = fullTranscription.transcription.buildOffsetsToIndices()
        
        return fullTranscription
    }
}



public extension Transcriber {
    
    func buildTranscription(from rawTranscription: RawTranscription) throws -> Transcription {
        let hydratedSegments = rawTranscription.segments
        let segments = mergeZeroDurationSegments(hydratedSegments)
        
        var rebuiltSegmentsCount = 0

        let wordTimeStamps = segments.enumerated().flatMap { (segIndex,seg) in
            let timeStamps = wordTimeStampsFrom(segment:seg, segmentIndex:segIndex, audioFile: seg.audioFile)
            let wordTimeStamps = tokenTimelineToWordTimeline(timeStamps)
            let spreadTimeStamps = spreadCollapsedRuns(wordTimeStamps: wordTimeStamps, segmentStart: seg.start, segmentEnd: seg.end)
            let adjustedTimeStamps = redistributeZeroDurations(wordTimeStamps: spreadTimeStamps, segmentStartTime: seg.start, segmentEndTime: seg.end)
            let (repairedTimeStamps,didRebuild) = fixOutOfWhackDurations(adjustedTimeStamps, segmentStart: seg.start, segmentEnd: seg.end, force: seg.needsRepair)

            rebuiltSegmentsCount += didRebuild ? 1 : 0
            if didRebuild {
                logger.log(.debug, "Rebuilt segement \(segIndex): \(seg.text)")
            }
            
            if repairedTimeStamps.hasDuplicateConsecutiveSpans()  {
                logger.log( .debug, "Transcription has duplicate consecutive spans in word timestamps" )
            }
            if repairedTimeStamps.hasOverlaps  {
                logger.log( .debug, "Transcription has overlaps word timestamps" )
            }

            return repairedTimeStamps
        }
            
        if wordTimeStamps.hasOverlaps {
            logger.log( .warn, "Transcription has overlaps in word timestamps" )
        }
        
        if wordTimeStamps.hasDuplicateConsecutiveSpans()  {
            logger.log( .warn, "Transcription has duplicate consecutive spans in word timestamps" )
        }
            
        let normalizedResults = normalizeToSpelledWords(wordTimeLine:wordTimeStamps)
        let transcriptionTxt = normalizedResults.map { $0.token }.joined()
        
        let indexedTimeStamps = normalizedResults.enumerated().map { ( index, timeStamp ) in
            var nuTimeStamp = timeStamp
            nuTimeStamp.index = index
            return nuTimeStamp
        }
        
        logger.log( .info, "Rebuilt \(rebuiltSegmentsCount) of \(segments.count) segments")
        
        let transcription = Transcription(transcription: transcriptionTxt, segments: segments, wordTimeline: indexedTimeStamps)
        return transcription
    }
    
    
    func mergeZeroDurationSegments(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        var result: [TranscriptionSegment] = []
        
        var i = 0
        while i < segments.count {
            let seg = segments[i]
            
            if !seg.isFastPaced && seg.start != seg.end {
                result.append(seg)
                i += 1
                continue
            }
            
            let next = (i < segments.count-1) ? segments[i+1] : nil
            if !result.isEmpty {
                let prev = result.removeLast()
                
                let nuText = prev.text + seg.text + (next?.text ?? "")
                let nuTokens = prev.tokens + seg.tokens + (next?.tokens ?? [])
                let nuEnd = (next?.end ?? seg.end)
                let nuSeg = TranscriptionSegment(text: nuText, start: prev.start, end: nuEnd, audioFile: seg.audioFile, tokens: nuTokens, needsRepair: true)
                result.append(nuSeg)
                i += next != nil ? 2 : 1
                continue
            }
            guard let next else {
                result.append(seg)
                i+=1
                continue
            }
            let nuText = seg.text + next.text
            let nuTokens = seg.tokens + next.tokens
            let nuEnd = next.end
            let nuSeg = TranscriptionSegment(text: nuText, start: seg.start, end: nuEnd, audioFile: seg.audioFile,tokens: nuTokens, needsRepair: true)
            result.append(nuSeg)
            i += 2
            continue
        }
        return result
    }
    
    func wordTimeStampsFrom( segment:TranscriptionSegment, segmentIndex:Int, audioFile:AudioFile ) -> [WordTimeStamp] {
        
        let transcriptionTokens = segment.tokens
        let timeStamps:[WordTimeStamp]  = transcriptionTokens.enumerated().map { (i, transcriptionToken: TranscriptionToken) -> WordTimeStamp in
            let tokenStr = transcriptionToken.text
            let dtw = transcriptionToken.dtw
            let a = transcriptionToken.start
            let b = transcriptionToken.end
            let rawStart = min(a, b)
            let rawEnd   = max(a, b)
            
            let (start,end ) = {
                if dtw < 0 {
                    return (rawStart, rawEnd)
                }
                
                let prevInfo = i > 0 ? transcriptionTokens[i - 1] : nil
                let nextInfo = i < transcriptionTokens.count - 1 ? transcriptionTokens[i + 1] : nil
                
                let prevAnchor = prevInfo?.dtw ?? rawStart
                let nextAnchor = nextInfo?.dtw ?? dtw
                
                if rawEnd == rawStart && dtw != prevAnchor && dtw != nextAnchor {
                    let start = (prevAnchor + dtw) / 2
                    let end   = (dtw + nextAnchor) / 2
                    return( start, end )
                }
                
                let start = max(rawStart, min((prevAnchor + dtw)/2, rawEnd))
                let end   = min(rawEnd,   max((dtw + nextAnchor)/2, rawStart))
                return (start,end)
            }()
            
            let timeStamp = WordTimeStamp( token: tokenStr, start: start, end: end,  audioFile: audioFile, transcriptionTokens:[transcriptionToken], segmentIndex: segmentIndex, tokenTypeGuess: .other , index:-1 )

            return timeStamp
        }
        return timeStamps
    }
    
    func redistributeZeroDurations(
        wordTimeStamps: [WordTimeStamp],
        segmentStartTime: Double,
        segmentEndTime: Double,
        minimumEpsilon: Double = 1e-9
    ) -> [WordTimeStamp] {

        var adjustedWordTimeStamps = wordTimeStamps
        let totalCount = adjustedWordTimeStamps.count
        var index = 0
        
        let hasZeroDur = wordTimeStamps.contains(where: { $0.end <= $0.start })
        if !hasZeroDur {
            return wordTimeStamps
        }

        while index < totalCount {
            let currentStartTime = adjustedWordTimeStamps[index].start
            let currentEndTime = adjustedWordTimeStamps[index].end
            if currentEndTime > currentStartTime + minimumEpsilon {
                index += 1
                continue
            }

            var leftIndex = max(0, index - 1)
            var rightIndex = min(totalCount - 1, index + 1)

            if totalCount == 1 {
                let newStartTime = segmentStartTime.roundToMs()
                let newEndTime = segmentEndTime.roundToMs()
                let adjustedTs = adjustedWordTimeStamps[0].with( start:newStartTime, end:newEndTime, isRebuilt:true)
                adjustedWordTimeStamps[0] = adjustedTs
                break
            }

            var leftBoundaryTime = (leftIndex > 0) ? adjustedWordTimeStamps[leftIndex - 1].end : segmentStartTime
            var rightBoundaryTime = (rightIndex + 1 < totalCount) ? adjustedWordTimeStamps[rightIndex + 1].start : segmentEndTime

            while rightBoundaryTime <= leftBoundaryTime + minimumEpsilon && (leftIndex > 0 || rightIndex + 1 < totalCount) {
                if leftIndex > 0 {
                    leftIndex -= 1
                    leftBoundaryTime = (leftIndex > 0) ? adjustedWordTimeStamps[leftIndex - 1].end : segmentStartTime
                }
                if rightBoundaryTime <= leftBoundaryTime + minimumEpsilon, rightIndex + 1 < totalCount {
                    rightIndex += 1
                    rightBoundaryTime = (rightIndex + 1 < totalCount) ? adjustedWordTimeStamps[rightIndex + 1].start : segmentEndTime
                }
                if leftIndex == 0 && rightIndex == totalCount - 1 { break }
            }

            if rightBoundaryTime <= leftBoundaryTime + minimumEpsilon {
                index += 1
                continue
            }

            let windowStartTime = leftBoundaryTime
            let windowEndTime = rightBoundaryTime
            let windowDuration = windowEndTime - windowStartTime

            let weightSum = adjustedWordTimeStamps[leftIndex...rightIndex].reduce(0.0) { $0 + Double($1.voiceLen) }
            let useEqualWeights = weightSum <= 0.0
            let windowTokenCount = rightIndex - leftIndex + 1


            var cumulativeTime = 0.0
            for k in leftIndex...rightIndex {
                let weight = useEqualWeights ? (1.0 / Double(windowTokenCount)): Double(adjustedWordTimeStamps[k].voiceLen) / weightSum
                let targetDuration = (k == rightIndex) ? (windowDuration - cumulativeTime) : windowDuration * weight
                
                let newStartTime = (windowStartTime + cumulativeTime).roundToMs()
                cumulativeTime += targetDuration
                let newEndTime = min(windowEndTime, windowStartTime + cumulativeTime).roundToMs()
                
                adjustedWordTimeStamps[k] = adjustedWordTimeStamps[k].with(start:newStartTime, end:newEndTime, isRebuilt: true/*, timeConfidence: 0.0*/ )
            }

            index = rightIndex + 1
        }

        return adjustedWordTimeStamps
    }
    
    func fixOutOfWhackDurations(
        _ stamps: [WordTimeStamp],
        segmentStart: Double,
        segmentEnd: Double,
        force:Bool ,
        tolerance: Double = 0.1
    ) -> ( [WordTimeStamp], Bool ) {
        
        let segmentDuration = segmentEnd - segmentStart
        let totalVlens = stamps.reduce(0) { $0 + $1.voiceLen }
        
        if segmentDuration <= 0 {
            return (stamps, false)
        }
        if totalVlens <= 0 {
            return (stamps, false)
        }
        if stamps.count < 2 {
            return (stamps, false)
        }
        if !force && stamps.count < 5 {
            return (stamps, false)
        }
        
        let badStamps = stamps.filter {
            //if session.granularity == .group && $0.timeConfidence > 0.04 {
                //return false
            //}
            let expectedDur = Double($0.voiceLen) / Double(totalVlens) * segmentDuration
            return abs( $0.duration - expectedDur) > tolerance
        }
        let badCount = badStamps.count
        let badLimit = Int(Double(stamps.count) * 0.8)
        if force || badCount >= badLimit {
            var out = [WordTimeStamp]()
            var cum = 0.0
            for ts in stamps {
                let dur   = Double(ts.voiceLen) / Double(totalVlens) * segmentDuration
                let start = segmentStart + cum
                cum += dur
                let end   = segmentStart + cum
                
                let roundedStart = start.roundToMs()
                let roundedEnd = end.roundToMs()

                let newTimeStamp = ts.with(start: roundedStart, end: roundedEnd, isRebuilt: true /*, timeConfidence: 0.0*/)
                out.append( newTimeStamp )
            }
            return ( out, true )
        }

        return (stamps, false)
    }
    
    func spreadCollapsedRuns(
        wordTimeStamps: [WordTimeStamp],
        segmentStart:   Double,
        segmentEnd:     Double
    ) -> [WordTimeStamp] {
        var out = [WordTimeStamp]()
        let count = wordTimeStamps.count
        let segmentFrames = wordTimeStamps.reduce(0) { $0 + $1.voiceLen }
 
        let frameDuration = segmentFrames > 0
            ? (segmentEnd - segmentStart) / Double(segmentFrames)
            : 0

        var i = 0
        while i < count {
            let s0 = wordTimeStamps[i].start
            let e0 = wordTimeStamps[i].end

            var j = i + 1
            while j < count
               && wordTimeStamps[j].start == s0
               && wordTimeStamps[j].end   == e0 {
                j += 1
            }

            let prevEnd = out.last?.end ?? segmentStart

            if j - i > 1 {
                let rawNextStart: Double = j < count ? wordTimeStamps[j].start : segmentEnd
                //let bound = rawNextStart > prevEnd ? rawNextStart : segmentEnd
                let bound = (j < count) ? max(prevEnd, rawNextStart) : segmentEnd

                let gap = max(0, bound - prevEnd)
                let run = wordTimeStamps[i..<j]
                let totalF = run.reduce(0) { $0 + $1.voiceLen }

                if totalF > 0 && gap > 0 {
                    var cum = 0.0
                    for ts in run {
                        let w     = ts.voiceLen / totalF
                        let start = prevEnd + cum * gap
                        cum += Double(w)
                        let end   = prevEnd + cum * gap
                        let clampedEnd = min( segmentEnd, end )
                        let roundedStart = start.roundToMs()
                        let roundedEnd = clampedEnd.roundToMs()
                        
                        out.append( ts.with( start:roundedStart, end:roundedEnd, isRebuilt: true ) )
                    }
                }
                else if totalF > 0 && gap == 0 && j == count {
                    var cumDur = 0.0
                    for ts in run {
                        let dur   = Double( ts.voiceLen ) * frameDuration
                        let start = prevEnd + cumDur
                        cumDur   += dur
                        let end   = prevEnd + cumDur
                        let clampedEnd = min( segmentEnd, end )
                        let roundedStart = start.roundToMs()
                        let roundedEnd = clampedEnd.roundToMs()
                        
                        out.append( ts.with( start:roundedStart, end:roundedEnd, isRebuilt: true ) )
                    }
                }
                else {
                    // There's no time to alot to these so just need to leave them alone. The confidences are already 0 anyway.
                    out.append(contentsOf: run)
                }
            }
            else {
                let ts = wordTimeStamps[i]
                let s = max(ts.start, prevEnd).roundToMs()
                let e = min(ts.end, segmentEnd).roundToMs()
                out.append( ts.with( start:s, end:e ))
            }

            i = j
        }

        return out
    }

    func tokenTimelineToWordTimeline(_ tokenTimelineInput: [WordTimeStamp] ) -> [WordTimeStamp] {
        let tokens = tokenTimelineInput
        var groups: [[WordTimeStamp]] = []
        for (idx, entry) in tokens.enumerated() {
            let text = entry.token
            let prevText = idx > 0 ? tokens[idx - 1].token : nil
            if groups.isEmpty || text.isEmpty || startsWithSeparatorCharacter(text) || (prevText.map(endsWithSeparatorCharacter) ?? false) {
                let concatSeparatedNumber:Bool = {
                    let numberSeparator = ","
                    guard let prevText else {
                        return false
                    }
                    if !prevText.hasSuffix(numberSeparator) && !text.hasPrefix(numberSeparator) {
                        return false
                    }
                    if prevText.hasSuffix(numberSeparator) && text.hasPrefix(numberSeparator) {
                        return false
                    }
                    if prevText.endsWithWhiteSpace {
                        return false
                    }
                    if text.startsWithWhiteSpace {
                        return false
                    }
                    if text.hasPrefix(numberSeparator) {
                        if prevText.trimmed().allSatisfy( { String($0) == numberSeparator || $0.isDigit } ) {
                            return true
                        }
                        return false
                    }
                    
                    if prevText.hasSuffix(numberSeparator) {
                        if text.trimmed().allSatisfy( { String($0) == numberSeparator || $0.isDigit } ) {
                            return true
                        }
                        return false
                    }
                    
                    return false
                }()
                
                if !concatSeparatedNumber {
                    groups.append([entry])
                    continue
                }
            }
            groups[groups.count - 1].append(entry)
        }
        
        var result: [WordTimeStamp] = []
        for group in groups {
            guard let first = group.first else { continue }
            
            let mergedBase = group.dropFirst().reduce(first) { acc, ts in
                acc.merged(with: ts)
            }
            
            if mergedBase.token.isEmpty { continue }
            
            let tokenTypeGuess: TokenTypeGuess = {
                if mergedBase.token.isAllWhiteSpaceOrPunct {
                    return .whiteSpaceAndPunct
                }
                let trimmedGrp = mergedBase.token.trimmed()
                if trimmedGrp.last! == "." {
                    return .sentenceEnd
                }
                if trimmedGrp.first!.isUppercase {
                    return .sentenceBegin
                }
                return .other
            }()
            
            let entry = mergedBase.with(
                tokenTypeGuess: tokenTypeGuess
            )
            result.append(entry)
        }
        return result
    }

    func isSeparatorCharacter(_ char: Character) -> Bool {
        let nonSeparatingPunctuation: Set<Character> = ["'", "-", ".","%", "·", "•"]
        //let nonSeparatingPunctuation: Set<Character> = ["'", "-", ".", "·", "•","\""]
        if nonSeparatingPunctuation.contains(char) { return false }
        return char.isWhitespace || char.isPunctuation
    }
    func startsWithSeparatorCharacter(_ text: String) -> Bool {
        if text.prefix(2) == "--" {
            return true
        }
        guard let first = text.first else { return false }
        return isSeparatorCharacter(first)
    }
    func endsWithSeparatorCharacter(_ text: String) -> Bool {
        if text.suffix(2) == "--" {
            return true
        }
        guard let last = text.last else { return false }
        return isSeparatorCharacter(last)
    }
    
    func ignoreSpecialToken(_ token:String ) -> Bool {
        let fullTokensToIgnore = ["<unk>", "[_EOS_]", "[_SOS_]", "[_EOT_]", "[_SOT_]", "[_TRANSLATE_]", "[_TRANSCRIBE_]",  "[_SOLM_]", "[_PREV_]" , "[_NOSP_]", "[_NOT_]" ]
        
        if fullTokensToIgnore.contains(token) {
            return true
        }
        
        let tokenPrefixesToIgnore: [String] = [ "[_TT_", "[_LANG_", "[_extra_token_" ]
        for pfx in tokenPrefixesToIgnore {
            if token.starts(with: pfx) {
                return true
            }
        }
        
        if token.starts(with: "[_") {
            logger.log(.debug, "Unkown special token \(token)" )
            return true
        }
        
        return false
    }
    
    func normalizeToSpelledWords( wordTimeLine: [WordTimeStamp]) -> [WordTimeStamp] {
        let normalizer = WordNormalizer()
        var offsetDelta = 0
        return wordTimeLine.map { wordTimeStamp in
            if wordTimeStamp.tokenTypeGuess == .whiteSpaceAndPunct {
                return wordTimeStamp
            }
            let startOffset = wordTimeStamp.startOffset >= 0 ? wordTimeStamp.startOffset + offsetDelta : -1
            let endOffset = wordTimeStamp.endOffset >= 0 ? wordTimeStamp.endOffset + offsetDelta : -1
            let (normalizedWord, delta) = normalizer.normalizedWord(wordTimeStamp.token)
            offsetDelta += delta
            
            return wordTimeStamp.with(token: normalizedWord, startOffset: startOffset, endOffset: endOffset, )
        }
    }
}
