//
// WordAligner.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//

import Foundation

struct Anchor {
    let wordIndex:Int
    let timeStampIndex:Int
    let timeStamps:[WordTimeStamp]
    
    var mergedTimeStamp:WordTimeStamp {
        var ts = timeStamps.first!
        for i in 1 ..< timeStamps.count {
            let nextTs = timeStamps[i]
            ts = ts.merged(with: nextTs)
        }
        return ts
    }
}

struct WordAligner : AlignmentSessionProviding {
    let session: AlignmentSession
    
    // This is pretty high, but the iOS apps seem to skip highlighting words that are shorter than this duration.
    //let minimumHighlightDuration = 0.15
    let minimumHighlightDuration = 0.19
    
    private let rightLeaningFunctionWords: Set<String> = [
        "to","of","in","on","at","by","for","from","as","with","into","than","then","that"
    ]

    private let neutralFunctionWords: Set<String> = [
        "a","an","the",
        "and","or","but",
        "this","those","these",
        "is","am","are","was","were","be","been","being",
        "he","she",
        "it","its","his","her","their","our","your","my","me","him","them","us","you","i"
    ]

    private var functionWordSet: Set<String> {
        rightLeaningFunctionWords.union(neutralFunctionWords)
    }
    private let boundaryWords = [".", "?", "!", ";", ":", "—", ","]
    
    private let anchorStopWords: Set<String> = [
        "a", "an", "in","of","to", "or","as","at","is","be", "it","its",
    ]
}

extension WordAligner {
    func alignWords( in alignedChapters: [AlignedChapter], granularity:Granularity ) async throws -> [AlignedChapter] {
        //let totalWordCount = alignedChapters.reduce(0) { $0 + $1.alignedSentencesWordCount }
        //progressTracker.updateProgress(for: .alignWords, event:.start, total: totalWordCount)
        
        let nThreads = sessionConfig.concurrency
        let wordChapters:[AlignedChapter] = try await alignedChapters.asyncMap(concurrency: nThreads) {
            try await alignWords(inChapter: $0, granularity: granularity)
        }
        //progressTracker.updateProgress(for: .alignWords, event: .end)
        return wordChapters
    }
    
    func alignWords( inChapter:AlignedChapter , granularity:Granularity ) async throws -> AlignedChapter {
        
        let wordSentences = try inChapter.alignedSentences.flatMap {
            try Task.checkCancellation()
            return alignWords(inSentence: $0, granularity:granularity)
        }
        
        let wordSentencesWithIds = wordSentences.enumerated().map { (index,alignedSentence) in
            let wordSentenceRange = alignedSentence.sentenceRange.with(id: index)
            let wordSentence = alignedSentence.with(sentenceId: index, sentenceRange: wordSentenceRange)
            return wordSentence
        }
        
        let alignedChapter = inChapter.with(  alignedWords: wordSentencesWithIds )
        return alignedChapter
    }
    
}

struct AlignedGroup {
    let wordStampTuples:[(word:String,stamp:WordTimeStamp)]
    
    init( wordStampTuples:[ (word:String,stamp:WordTimeStamp) ] ) {
        self.wordStampTuples = wordStampTuples
    }
    
    init( from wordTimeStamps:[WordTimeStamp], words: [String], groupStartIndex:Int, groupEndIndex:Int ) {
        self.wordStampTuples = Array(zip(words[groupStartIndex...groupEndIndex], wordTimeStamps[groupStartIndex...groupEndIndex] ))
    }
    
    var anyInterpolated:Bool {
        (wordStampTuples.first { $0.stamp.isInterpolated }) != nil
    }
    var anyRebuilt:Bool {
        (wordStampTuples.first { $0.stamp.isRebuilt }) != nil
    }
    var mergedToken:String {
        wordStampTuples.map { $0.stamp.token }.joined()
    }
    var mergedWord:String {
        wordStampTuples.map( \.word ).joined()
    }
    var mergedStamp: WordTimeStamp {
        wordStampTuples
            .map { $0.stamp }
            .dropFirst()
            .reduce(wordStampTuples.first!.stamp) { $0.merged(with: $1) }
    }
    var timeStamp:WordTimeStamp {
        mergedStamp
    }
    
}

extension WordAligner {
    
    func alignWords( inSentence:AlignedSentence, granularity:Granularity ) -> [AlignedSentence] {
        logger.log( .debug, "Aligning words inSentence \(inSentence.description)")
        
        defer {
            progressTracker.updateProgress(for: .alignWords,  increment:inSentence.xhtmlSentenceWords.count)
        }
        
        let timeStamps = coalescePunctOnlyTimeStamps(timeStamps: inSentence.sentenceRange.timeStamps)
        let uncorrectedTimeStamps = timeStamps.map { ts in
            return ts.with(start:ts.origStart, end:ts.origEnd, isRebuilt:false)
        }
        let initialAlignment = align( timeStamps:uncorrectedTimeStamps, toWords:inSentence.xhtmlSentenceWords, sentenceRange:inSentence.sentenceRange )

        let (alignedTimeStamps, words ) = {
            let clampedStamps = clamp(timeStamps: initialAlignment, sentenceRange: inSentence.sentenceRange)
            if granularity == .word {
                return (clampedStamps, inSentence.xhtmlSentenceWords)
            }
            let groups = {
                if granularity == .segment {
                    return buildSegmentGroups(wordTimeStamps: clampedStamps, words: inSentence.xhtmlSentenceWords)
                }
                return buildAutoPhraseGroups(wordTimeStamps: clampedStamps, words: inSentence.xhtmlSentenceWords)
            }()
            let tupleWords = groups.map { $0.mergedWord }
            let tupleStamps = groups.map { $0.mergedStamp }
            return( tupleStamps, tupleWords)
        }()
        
        logger.log( .debug, "Aligned words " + alignedTimeStamps.map { $0.token }.joined() + "\n\n" )
        
        let contiguousTimeStamps = alignedTimeStamps.pairs().map { (prev,cur) in
            guard let prev else {
                return cur
            }
            guard prev.audioFile.filePath == cur.audioFile.filePath else {
                return cur
            }
            logger.log( .debug,  "\(cur.token):  Gap:\(cur.start - prev.end )  Duration:\(cur.duration)")
            return cur.with( start:prev.end  )
        }
        
        let alignedSentences = words.enumerated().map { (index,chapterWord) in
            let timeStamp = contiguousTimeStamps[index]
            let wordSentenceRange = SentenceRange(id: index, start: timeStamp.start, end: timeStamp.end, audioFile: timeStamp.audioFile, timeStamps: [timeStamp] )
            let wordSentence = AlignedSentence(xhtmlSentence: chapterWord, sentenceId: index, sentenceRange: wordSentenceRange, matchText: timeStamp.token, matchOffset: 0, matchType: .none)
            return wordSentence
        }
        return alignedSentences
    }
    
    
    func clamp(timeStamps:[WordTimeStamp], sentenceRange:SentenceRange ) -> [WordTimeStamp] {
        if timeStamps.count < 2  {
            return [timeStamps.first!.with(start:sentenceRange.start, end:sentenceRange.end)]
        }
        
        if timeStamps.first!.end <= sentenceRange.start {
            logger.log( .debug, "Bad duration when clamping: \(timeStamps.first!.description). This usually indicates a bad alignment")
        }
        let firstTs = timeStamps.first!.with( start:sentenceRange.start )
        
        if sentenceRange.end <= timeStamps.last!.start {
            logger.log( .debug, "Bad duration when clamping: \(timeStamps.last!.description). This usually indicates a bad alignment")
        }
        let lastTs = timeStamps.last!.with( end:sentenceRange.end )
        if timeStamps.count < 3 {
            return [firstTs, lastTs]
        }
        return [firstTs] + Array( timeStamps[1..<timeStamps.count-1] ) + [lastTs]
    }
    
    func coalescePunctOnlyTimeStamps( timeStamps:[WordTimeStamp] ) -> [WordTimeStamp] {
        var nuTimeStamps:[WordTimeStamp] = []
        var i = 0
        while i < timeStamps.count {
            var ts = timeStamps[i]
            var j = i + 1
            while j < timeStamps.count {
                let nextTs = timeStamps[j]
                guard nextTs.tokenTypeGuess == .whiteSpaceAndPunct && nextTs.segmentIndex == ts.segmentIndex else {
                    break
                }
                ts = ts.merged(with: nextTs)
                j += 1
            }
            nuTimeStamps.append(ts)
            i = j
        }
        let firstIdx = nuTimeStamps.first!.index
        let indexedTimeStamps = nuTimeStamps.enumerated().map { (index,ts) in
            ts.with( index:firstIdx+index)
        }
        return indexedTimeStamps
    }
    
    func isHardBoundaryToken(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.contains(anyOf: boundaryWords )
    }
    
    func normalize( word:String ) -> String {
        let (firstPass,_) = WordNormalizer().normalizedWord(word)
        return firstPass.lowercased().removePunctuation().trimmed()
    }
}

extension WordAligner {

    func buildSegmentGroups( wordTimeStamps: [WordTimeStamp],  words: [String] ) -> [AlignedGroup] {
        
        let totalWordCount = min(wordTimeStamps.count, words.count)
        if totalWordCount == 0 { return [] }

        var groups: [AlignedGroup] = []
        var wordIndex = 0

        while wordIndex < totalWordCount {
            let groupStartIndex = wordIndex
            let groupStartStamp = wordTimeStamps[groupStartIndex]
            var groupEndIndex = groupStartIndex

            while (groupEndIndex + 1) < totalWordCount {
                let leftIdx = groupEndIndex
                let rightIdx = groupEndIndex + 1
                let leftStamp = wordTimeStamps[leftIdx]
                let rightStamp = wordTimeStamps[rightIdx]
                
                if leftStamp.audioFile.filePath != groupStartStamp.audioFile.filePath  || leftStamp.segmentIndex != groupStartStamp.segmentIndex {
                    break
                }
                if rightStamp.audioFile.filePath != groupStartStamp.audioFile.filePath || rightStamp.segmentIndex != groupStartStamp.segmentIndex {
                    break
                }
                groupEndIndex = rightIdx
            }
            let wordStampGroup = AlignedGroup(from: wordTimeStamps, words: words, groupStartIndex: groupStartIndex, groupEndIndex: groupEndIndex)
            groups.append(wordStampGroup)
            wordIndex = groupEndIndex + 1
        }

        return groups
    }
    
    
    func buildAutoPhraseGroups( wordTimeStamps: [WordTimeStamp],  words: [String] ) -> [AlignedGroup] {
        
        // This is intentionally high so that the other heuritics are used to break up groups. Most sentences themselves should have less words than this, so the only way this should be exceeded is on a really big sentence with lots of really short words maybe.
        let maxWordsPerGroup = 64
        
        let shortWordThreshold = 0.30
        let minDesiredGroupDuration = 0.6
        let basePauseThreshold = 0.1
        let baseMaxDesiredGroupDuration = minDesiredGroupDuration
        let boostedMaxDesiredGroupDuration = 2.0
        let boostedPauseThreshold = 0.35
        let unreliableDurationThreshold = 0.04
        let unreliableTimeConfidenceThreshold = 0.0
        //let unreliableTimeConfidenceThreshold = 0.012
        let reliableDurationThreshold = 0.25
        let reliableTimeConfidenceThreshold = 0.4
       
        
        let totalWordCount = min(wordTimeStamps.count, words.count)
        if totalWordCount == 0 { return [] }

        func isFunctionWord(_ token: String) -> Bool {
            functionWordSet.contains( token )
        }

        var groups: [AlignedGroup] = []
        var wordIndex = 0

        while wordIndex < totalWordCount {
            let groupStartIndex = wordIndex
            let groupStartStamp = wordTimeStamps[groupStartIndex]
            var groupEndIndex = groupStartIndex
            var boostedMode = false

            while (groupEndIndex + 1) < totalWordCount {
                let wordsInGroup = groupEndIndex - groupStartIndex + 1

                let leftIdx = groupEndIndex
                let rightIdx = groupEndIndex + 1
                
                let leftStamp = wordTimeStamps[leftIdx]
                let rightStamp = wordTimeStamps[rightIdx]
                
                let leftWord = words[leftIdx]
                let normalizedLeftWord = normalize(word: leftWord)
                let rightWord = words[rightIdx]
                let normalizedRightWord = normalize(word: rightWord)
                
                if !wordTimeStamps[groupEndIndex+1].isInterpolated && wordsInGroup >= maxWordsPerGroup {
                    let str = words[groupStartIndex...groupEndIndex].joined( separator: " ")
                    logger.log( .warn, "Splitting extra large word group \(str) at: \(rightWord)" )
                    break
                }
                
                let leftDuration = max(0.0, leftStamp.duration)
                let rightDuration = max(0.0, rightStamp.duration)
                
                let isLeftFirstInSegment = (leftIdx == 0 || wordTimeStamps[leftIdx - 1].segmentIndex != leftStamp.segmentIndex)
                let isRightFirstInSegment = (wordTimeStamps[rightIdx - 1].segmentIndex != rightStamp.segmentIndex)
                let leftUnreliable = /*leftStamp.isRebuilt ||*/ (!isLeftFirstInSegment && leftStamp.timeConfidence <= unreliableTimeConfidenceThreshold) || leftDuration <= unreliableDurationThreshold
                let rightUnreliable = /*rightStamp.isRebuilt ||*/ (!isRightFirstInSegment && rightStamp.timeConfidence <= unreliableTimeConfidenceThreshold) || rightDuration <= unreliableDurationThreshold

                let isUnreliable = (leftUnreliable || rightUnreliable)
                if isUnreliable {
                    boostedMode = true
                }
                else {
                    let leftReliable = leftStamp.timeConfidence >= reliableTimeConfidenceThreshold && leftDuration >= reliableDurationThreshold
                    let rightReliable = rightStamp.timeConfidence >= reliableTimeConfidenceThreshold && rightDuration >= reliableDurationThreshold
                    if boostedMode && leftReliable && rightReliable {
                        boostedMode = false
                    }
                }
                
                let effectivePauseThreshold = boostedMode ? boostedPauseThreshold : basePauseThreshold
                let effectiveMaxDesiredGroupDuration = boostedMode ? boostedMaxDesiredGroupDuration : baseMaxDesiredGroupDuration
                
                let gapToNext = rightStamp.start - leftStamp.end
                let mustMerge = isUnreliable || leftStamp.isInterpolated || rightStamp.isInterpolated

                if leftStamp.audioFile.filePath != groupStartStamp.audioFile.filePath  || leftStamp.segmentIndex != groupStartStamp.segmentIndex { break }
                if rightStamp.audioFile.filePath != groupStartStamp.audioFile.filePath || rightStamp.segmentIndex != groupStartStamp.segmentIndex { break }
                                                
                if isHardBoundaryToken(leftWord) && leftDuration > 0 && rightDuration > 0 {
                    break
                }
                
                if !mustMerge && (gapToNext < 0 || gapToNext > effectivePauseThreshold) {
                    break
                }
                
                let oneShort = (leftDuration < shortWordThreshold) || (rightDuration < shortWordThreshold)
                let pairShort = (leftDuration + rightDuration) < minDesiredGroupDuration
                let eitherFunction = isFunctionWord(normalizedLeftWord) || isFunctionWord(normalizedRightWord)
                
                var shouldGroup = mustMerge || pairShort || (oneShort && (eitherFunction || boostedMode) )

                if shouldGroup {
                    let cumulativeDuration = (wordTimeStamps[rightIdx].end - wordTimeStamps[groupStartIndex].start)
                    if !mustMerge && cumulativeDuration >= effectiveMaxDesiredGroupDuration {
                        shouldGroup = false
                    }
                }

                if !shouldGroup { break }
                groupEndIndex = rightIdx
            }

            let group = AlignedGroup(from: wordTimeStamps, words: words, groupStartIndex: groupStartIndex, groupEndIndex: groupEndIndex)
            groups.append(group)
            wordIndex = groupEndIndex + 1
        }
        
        let repairedGroups = repairShortGroups(groups)
        let finalizedGroups = applyRightLeaningFunctionWords(repairedGroups)
        
        return finalizedGroups
    }
    
    private func repairShortGroups(_ groups: [AlignedGroup]) -> [AlignedGroup] {
        if groups.count <= 1 { return groups }

        //let minConfidence = 0.0399

        func mergedGroup(_ left: AlignedGroup, _ right:AlignedGroup ) -> AlignedGroup {
            AlignedGroup( wordStampTuples:left.wordStampTuples + right.wordStampTuples )
        }
        
        var result: [AlignedGroup] = []
        var index = 0
        
        while index < groups.count {
            let group = groups[index]
            let duration = group.timeStamp.duration
            
            if duration >= minimumHighlightDuration || groups.count == 1 {
                result.append(group)
                index += 1
                continue
            }
            
            logger.log(.debug, "Found group with short duration \(duration), words:\(group.mergedWord)")
            
            if index == 0 {
                let merged = mergedGroup(group, groups[index + 1])
                result.append(merged)
                index += 2
                continue
            }
            
            if index == groups.count - 1 {
                let last = result.removeLast()
                let merged = mergedGroup(last, group)
                result.append(merged)
                index += 1
                continue
            }
            
            let leftNeighbor = result.last!
            let rightNeighbor = groups[index + 1]
            
            let leftCombinedDuration = leftNeighbor.timeStamp.duration + duration
            let rightCombinedDuration = duration + rightNeighbor.timeStamp.duration
            
            let mergeWithLeft: Bool
            if leftCombinedDuration >= minimumHighlightDuration && rightCombinedDuration >= minimumHighlightDuration {
                mergeWithLeft = abs(leftCombinedDuration - minimumHighlightDuration) <= abs(rightCombinedDuration - minimumHighlightDuration)
            } else if leftCombinedDuration >= minimumHighlightDuration {
                mergeWithLeft = true
            } else if rightCombinedDuration >= minimumHighlightDuration {
                mergeWithLeft = false
            } else {
                mergeWithLeft = abs(leftCombinedDuration - minimumHighlightDuration) <= abs(rightCombinedDuration - minimumHighlightDuration)
            }
            
            if mergeWithLeft {
                let last = result.removeLast()
                let merged = mergedGroup(last, group)
                result.append(merged)
                index += 1
            } else {
                let merged = mergedGroup(group, rightNeighbor)
                result.append(merged)
                index += 2
            }
        }
        
        return result
    }
    
    private func applyRightLeaningFunctionWords(_ groups: [AlignedGroup]) -> [AlignedGroup] {
        if groups.count <= 1 { return groups }
        
        var result = groups
        var index = 0
        
        while index < result.count - 1 {
            let current = result[index]
            let next = result[index + 1]
            
            guard let lastTuple = current.wordStampTuples.last else {
                index += 1
                continue
            }
            if current.wordStampTuples.count <= 1 {
                index += 1
                continue
            }
            
            let normalizedLastWord = normalize(word: lastTuple.word)
            
            let treatAsRightLeaning: Bool = {
                if rightLeaningFunctionWords.contains(normalizedLastWord) {
                    return true
                }
                let curCount = current.wordStampTuples.count
                if curCount < 2 {
                    return false
                }
                let secondToLastWord = current.wordStampTuples[curCount - 2].word
                if !isHardBoundaryToken(secondToLastWord) {
                    return false
                }
                return true
            }()
            if !treatAsRightLeaning {
                index += 1
                continue
            }
            
            logger.log(.debug, "Found right leaning word: \(normalizedLastWord)")
            
            let lastDuration = max(0.0, lastTuple.stamp.duration)
            let currentDuration = current.timeStamp.duration
            let nextDuration = next.timeStamp.duration
            
            let currentAfter = currentDuration - lastDuration
            let nextAfter = nextDuration + lastDuration
            
            if currentAfter < minimumHighlightDuration || nextAfter < minimumHighlightDuration {
                index += 1
                continue
            }
            
            var currentTuples = current.wordStampTuples
            _ = currentTuples.popLast()
            var nextTuples = next.wordStampTuples
            nextTuples.insert(lastTuple, at: 0)
            
            result[index] = AlignedGroup(wordStampTuples: currentTuples)
            result[index + 1] = AlignedGroup(wordStampTuples: nextTuples)
            
            index += 1
        }
        
        return result
    }
}

extension WordAligner {
    func align( timeStamps:[WordTimeStamp], toWords:[String], sentenceRange:SentenceRange ) -> [WordTimeStamp] {
        if timeStamps.count == toWords.count {
            if timeStamps.isEmpty {
                return []
            }
            logger.log( .debug, "Aligning words - counts match", indentLevel: 1)
            return timeStamps
        }
        
        logger.log( .debug,  "Aligning words - handling missing", indentLevel: 1)
        var anchors = buildAnchors(timeStamps: timeStamps, words: toWords)
        if anchors.count == toWords.count {
            let alignedTimeStamps = anchors.map { $0.mergedTimeStamp }
            return alignedTimeStamps
        }
        
        if anchors.isEmpty {
            let firstStartTime = sentenceRange.start //      timeStamps.first!.start
            let lastEndTime    = sentenceRange.end   //     timeStamps.last!.end
            return buildInterpolatedTimeStamps(wordsSlice: toWords[0..<toWords.count], startTime: firstStartTime, endTime: lastEndTime, template: timeStamps.first!)
        }
        
        var alignedTimeStamps:[WordTimeStamp] = []
        alignedTimeStamps += fillHeadGap(anchors: &anchors, timeStamps: timeStamps, words: toWords, sentenceRange:sentenceRange)
        alignedTimeStamps += fillMiddle(anchors: anchors, timeStamps: timeStamps, words: toWords )
        let tailResult = fillTailGap(anchors: anchors, timeStamps: timeStamps, words: toWords)
        if !tailResult.replacementAnchorTail.isEmpty {
            alignedTimeStamps.removeLast(tailResult.replacementAnchorTail.count)
            alignedTimeStamps.append(contentsOf: tailResult.replacementAnchorTail)
        }
        alignedTimeStamps.append(contentsOf: tailResult.tail)
        
        if alignedTimeStamps.count > toWords.count {
            logger.log(.debug, "Count mistmatch at end of alignWords.count > toWords.count -- This should never happen.")
            return Array(alignedTimeStamps.prefix(toWords.count))
        }
        
        if alignedTimeStamps.count < toWords.count {
            logger.log(.debug, "Count mistmatch at end of alignWords.count < toWords.count -- This should never happen.")
            //reallocateTailByPeelingLast(alignedTimeStamps: &alignedTimeStamps, toWords: toWords, allTimeStamps: timeStamps)
        }
        
        return alignedTimeStamps
    }
}

extension WordAligner {
    
    func buildAnchors(timeStamps: [WordTimeStamp], words: [String]) -> [Anchor] {
        
        var anchors: [Anchor] = []
        var wordIndex = 0
        var timeStampIndex = 0
        let maxMergedTokens = 3
        
        var lastSkipSide: SkipSide? = nil
        var consecutiveSkipCount = 0
        let maxConsecutiveSkipsPerSide = 3
        
        
        while wordIndex < words.count && timeStampIndex < timeStamps.count {
            let currentWord = words[wordIndex]
            
            var combinedTimeStampTokens: [WordTimeStamp] = []
            var combinedTimeStampToken = ""
            var mergeIndex = timeStampIndex
            var didMatch = false
            
            let mergeEndExclusive = min(timeStamps.count, timeStampIndex + maxMergedTokens)
            while mergeIndex < mergeEndExclusive {
                let ts = timeStamps[mergeIndex]
                combinedTimeStampTokens.append(ts)
                combinedTimeStampToken += ts.token
                if matches(word: currentWord, tsToken: combinedTimeStampToken) {
                    anchors.append(Anchor(wordIndex: wordIndex, timeStampIndex: timeStampIndex, timeStamps: combinedTimeStampTokens))
                    wordIndex += 1
                    timeStampIndex = mergeIndex + 1
                    didMatch = true
                    lastSkipSide = nil
                    consecutiveSkipCount = 0
                    break
                }
                mergeIndex += 1
            }
            if didMatch { continue }
            
            //var decidedSkipSide = decideSkipSide(wordIndex: wordIndex, timeStampIndex: timeStampIndex, words:words, timeStamps: timeStamps)
            let maxLookahead = 6
            
            let dSkipWord = nextMatchDistance(
                wordIndex: wordIndex + 1,
                timeStampIndex: timeStampIndex,
                words: words,
                timeStamps: timeStamps,
                maxMergedTokens: maxMergedTokens,
                maxLookahead: maxLookahead
            )
            
            let dSkipTs = nextMatchDistance(
                wordIndex: wordIndex,
                timeStampIndex: timeStampIndex + 1,
                words: words,
                timeStamps: timeStamps,
                maxMergedTokens: maxMergedTokens,
                maxLookahead: maxLookahead
            )
            
            var decidedSkipSide: SkipSide
            if let dw = dSkipWord, let dt = dSkipTs {
                decidedSkipSide = (dw <= dt) ? .word : .timestamp
            } else if dSkipWord != nil {
                decidedSkipSide = .word
            } else if dSkipTs != nil {
                decidedSkipSide = .timestamp
            } else {
                decidedSkipSide = decideSkipSide(wordIndex: wordIndex, timeStampIndex: timeStampIndex, words: words, timeStamps: timeStamps)
            }
            
            if let last = lastSkipSide, last == decidedSkipSide, consecutiveSkipCount >= maxConsecutiveSkipsPerSide {
                decidedSkipSide = (decidedSkipSide == .timestamp) ? .word : .timestamp
                consecutiveSkipCount = 0
            }
            
            if decidedSkipSide == .timestamp {
                timeStampIndex += 1
            }
            else {
                wordIndex += 1
            }
            
            if lastSkipSide == decidedSkipSide {
                consecutiveSkipCount += 1
            } else {
                lastSkipSide = decidedSkipSide
                consecutiveSkipCount = 1
            }
        }
        
        return anchors
    }
    
    func matches( word:String, tsToken:String ) -> Bool {
        let normalizedWord = normalize(word: word.trimmed())
        let normalizedTsToken = normalize(word:tsToken.trimmed())
        
        let key = anchorKey(normalizedWord)
        if normalizedWord == normalizedTsToken {
            if anchorStopWords.contains(key) { return false }
            return true
        }
        if normalizedWord.count < 4 || normalizedTsToken.count < 3 {
            return false
        }
        
        
        let biggerWordLen = max( normalizedWord.count, normalizedTsToken.count)
        let maxDist = max(Int(floor(0.25 * Double(biggerWordLen))), 1)
        
        if( abs(normalizedTsToken.count - normalizedWord.count) > maxDist ) {
            return false
        }
        
        guard let (match,index) = FuzzySearcher().findNearestMatch(needle: normalizedWord, haystack: normalizedTsToken, maxDist: maxDist) else {
            return false
        }
        
        if match.count == normalizedTsToken.count {
            if anchorStopWords.contains(key) { return false }
            return true
        }
        let slack = min(2, maxDist)
        if index == 0 && (normalizedTsToken.count - match.count) <= slack && (match.count >= normalizedWord.count - slack) && Double(match.count) / Double(biggerWordLen) >= 0.85 {
            if anchorStopWords.contains(key) { return false }
            return true
        }
        
        return false
    }
    
    private func anchorKey(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
    }

    
    enum SkipSide { case word, timestamp }
    
    private func nextMatchDistance(
        wordIndex: Int,
        timeStampIndex: Int,
        words: [String],
        timeStamps: [WordTimeStamp],
        maxMergedTokens: Int,
        maxLookahead: Int
    ) -> Int? {
        guard wordIndex < words.count, timeStampIndex < timeStamps.count else { return nil }
        
        func hasMatch(wi: Int, ti: Int) -> Bool {
            guard wi < words.count, ti < timeStamps.count else { return false }
            let w = words[wi]
            var combined = ""
            var mi = ti
            let end = min(timeStamps.count, ti + maxMergedTokens)
            while mi < end {
                combined += timeStamps[mi].token
                if matches(word: w, tsToken: combined) { return true }
                mi += 1
            }
            return false
        }
        
        for total in 0...maxLookahead {
            for dw in 0...total {
                let dt = total - dw
                if hasMatch(wi: wordIndex + dw, ti: timeStampIndex + dt) { return total }
            }
        }
        return nil
    }
    
    
    func decideSkipSide(wordIndex: Int, timeStampIndex: Int, words:[String], timeStamps:[WordTimeStamp] ) -> SkipSide {
        let currentTs = timeStamps[timeStampIndex]
        let currentDuration = currentTs.end - currentTs.start
        
        var decided: SkipSide? = nil
        
        /*
         if wordIndex + 1 < words.count {
         let currentWordMatchesCurrentTs = matches(word: words[wordIndex], tsToken: currentTs.token)
         let nextWordMatchesCurrentTs = matches(word: words[wordIndex + 1], tsToken: currentTs.token)
         if !currentWordMatchesCurrentTs && nextWordMatchesCurrentTs { decided = .word }
         }*/
        
        var neighborDurations: [Double] = []
        if timeStampIndex + 1 < timeStamps.count {
            neighborDurations.append(timeStamps[timeStampIndex + 1].end - timeStamps[timeStampIndex + 1].start)
        }
        if timeStampIndex > 0 {
            neighborDurations.append(timeStamps[timeStampIndex - 1].end - timeStamps[timeStampIndex - 1].start)
        }
        if let avg = neighborDurations.isEmpty ? nil : (neighborDurations.reduce(0, +) / Double(neighborDurations.count)) {
            if currentDuration < 0.25 * avg { decided = .timestamp }
            else if currentDuration > 2.5 * avg { decided = .word }
        }
        
        if decided == nil {
            let canPeekNextTs = timeStampIndex + 1 < timeStamps.count
            let canPeekNextWord = wordIndex + 1 < words.count
            let wordMatchesNextTs = canPeekNextTs ? matches(word: words[wordIndex], tsToken: timeStamps[timeStampIndex + 1].token) : false
            let nextWordMatchesCurrentTs = canPeekNextWord ? matches(word: words[wordIndex + 1], tsToken: currentTs.token) : false
            
            if wordMatchesNextTs && !nextWordMatchesCurrentTs { decided = .timestamp }
            else if nextWordMatchesCurrentTs && !wordMatchesNextTs { decided = .word }
        }
        
        if decided == nil {
            let remainingTimeStampCount = timeStamps.count - timeStampIndex
            let remainingWordCount = words.count - wordIndex
            if remainingTimeStampCount > remainingWordCount { decided = .timestamp }
            else if remainingWordCount > remainingTimeStampCount { decided = .word }
            else { decided = .timestamp }
        }
        
        return decided!
    }
}

extension WordAligner {
    
    func fillHeadGap( anchors: inout [Anchor], timeStamps:[WordTimeStamp], words:[String], sentenceRange:SentenceRange ) -> [WordTimeStamp] {
        let firstAnchor = anchors[0]
        guard firstAnchor.wordIndex > 0 else {
            //return [firstAnchor.mergedTimeStamp]
            return []
        }
        //let headStartTime = timeStamps.first!.start
        let headStartTime = sentenceRange.start
        let headEndTime   = timeStamps[firstAnchor.timeStampIndex].start
        let headWaypoints = collectWaypointsBetween(timeStamps: timeStamps, leftAnchorEndIndex: -1, rightAnchorStartIndex: firstAnchor.timeStampIndex)
        
        if headEndTime > headStartTime {
            let alignedTimeStamps = fillGapUsingWaypoints(
                words: words,
                wordsStartIndex: 0,
                wordsEndIndexExclusive: firstAnchor.wordIndex,
                startBoundTime: headStartTime,
                endBoundTime: headEndTime,
                waypoints: headWaypoints,
                template: timeStamps[0]
            )
            //return alignedTimeStamps + [firstAnchor.mergedTimeStamp]
            return alignedTimeStamps
        }
        
        let aligned = reallocateHeadByPeelingFirstAnchor(
            firstAnchor: firstAnchor,
            timeStamps: timeStamps,
            words: words,
            sentenceRange: sentenceRange
        )
        //let anchorCount = max(1, firstAnchor.timeStamps.count)
        let anchorCount = 1
        let cut = min(anchorCount, aligned.count)
        let head = Array(aligned.dropLast(cut))
        let newAnchorStamps = Array(aligned.suffix(cut))
        anchors[0] = Anchor(wordIndex: firstAnchor.wordIndex, timeStampIndex: firstAnchor.timeStampIndex, timeStamps: newAnchorStamps)
        return head
        //return aligned
    }


    func fillMiddle(anchors: [Anchor], timeStamps: [WordTimeStamp], words: [String]) -> [WordTimeStamp] {
        var out: [WordTimeStamp] = []
        
        guard anchors.count >= 1 else { return out }
        
        out.append(anchors[0].mergedTimeStamp)
        
        guard anchors.count >= 2 else { return out }

        var i = 0
        while i < anchors.count - 1 {
            var k = i
            while k + 1 < anchors.count {
                let gwStart = anchors[k].wordIndex + 1
                let gwEnd   = anchors[k + 1].wordIndex
                if gwStart < gwEnd { break }
                out.append(anchors[k + 1].mergedTimeStamp)
                k += 1
            }
            if k == anchors.count - 1 { break }

            let left  = anchors[k]
            let right = anchors[k + 1]

            let gapWordStart = left.wordIndex + 1
            let gapWordEnd   = right.wordIndex
            let leftEndIndex = left.timeStampIndex + max(0, left.timeStamps.count - 1)
            let gapStartTime = timeStamps[leftEndIndex].end
            let gapEndTime   = timeStamps[right.timeStampIndex].start

            if gapWordStart < gapWordEnd && gapEndTime > gapStartTime {
                let gapWaypoints = collectWaypointsBetween(
                    timeStamps: timeStamps,
                    leftAnchorEndIndex: leftEndIndex,
                    rightAnchorStartIndex: right.timeStampIndex
                )
                let templateTs = left.timeStamps.last ?? timeStamps[leftEndIndex]
                out += fillGapUsingWaypoints(
                    words: words,
                    wordsStartIndex: gapWordStart,
                    wordsEndIndexExclusive: gapWordEnd,
                    startBoundTime: gapStartTime,
                    endBoundTime: gapEndTime,
                    waypoints: gapWaypoints,
                    template: templateTs
                )
                out.append(right.mergedTimeStamp)
            } else if gapWordStart < gapWordEnd {
                let adjustedStamp = redistributeZeroWidthMiddle(
                    alignedTimeStamps: &out,
                    leftAnchor: left,
                    rightAnchor: right,
                    words: words
                )
                out.append(adjustedStamp)
            } else {
                out.append(right.mergedTimeStamp)
            }

            i = k + 1
        }

        return out
    }
    
    func fillTailGap(anchors: [Anchor], timeStamps: [WordTimeStamp], words: [String]) -> (replacementAnchorTail: [WordTimeStamp], tail: [WordTimeStamp]) {

        let lastAnchor = anchors.last!
        let lastAnchorEndIndex = lastAnchor.timeStampIndex + max(0, lastAnchor.timeStamps.count - 1)
        guard lastAnchor.wordIndex + 1 < words.count else {
            return ([], [])
        }

        let tailStartTime = timeStamps[lastAnchorEndIndex].end
        let tailEndTime   = timeStamps.last!.end

        /*
        if tailStartTime >= tailEndTime {
            let anchorStampCount = max(1, lastAnchor.timeStamps.count)

            var out: [WordTimeStamp] = lastAnchor.timeStamps
            if out.isEmpty {
                out = [timeStamps[lastAnchorEndIndex]]
            }

            let combinedWords = Array(words[lastAnchor.wordIndex..<words.count])

            reallocateTailByPeelingLast(
                alignedTimeStamps: &out,
                toWords: combinedWords,
                allTimeStamps: timeStamps
            )

            let cut = min(anchorStampCount, out.count)
            let replacementAnchorTail = Array(out.prefix(cut))
            let tail = Array(out.dropFirst(cut))
            return (replacementAnchorTail, tail)
        }
         */
        if tailStartTime >= tailEndTime {
            let anchorMerged = lastAnchor.mergedTimeStamp
            let reallocationStartTime = anchorMerged.start
            let rawReallocationEndTime = timeStamps.last!.end
            let reallocationEndTime = max(rawReallocationEndTime, reallocationStartTime)
            
            let combinedWords = words[lastAnchor.wordIndex..<words.count]
            let redistributed = buildInterpolatedTimeStamps(
                wordsSlice: combinedWords,
                startTime: reallocationStartTime,
                endTime: reallocationEndTime,
                template: anchorMerged
            )
            
            guard !redistributed.isEmpty else {
                return ([], [])
            }
            
            let replacementAnchorTail = [redistributed.first!]
            let tail = Array(redistributed.dropFirst())
            return (replacementAnchorTail, tail)
        }

        let tailWaypoints: [WordTimeStamp] =
            (lastAnchorEndIndex + 1 < timeStamps.count)
            ? Array(timeStamps[(lastAnchorEndIndex + 1)..<timeStamps.count])
            : []

        let templateTs = lastAnchor.timeStamps.last ?? timeStamps[lastAnchorEndIndex]

        let tail = fillGapUsingWaypoints(
            words: words,
            wordsStartIndex: lastAnchor.wordIndex + 1,
            wordsEndIndexExclusive: words.count,
            startBoundTime: tailStartTime,
            endBoundTime: tailEndTime,
            waypoints: tailWaypoints,
            template: templateTs
        )

        return ([], tail)
    }
    
    private func collectWaypointsBetween(timeStamps: [WordTimeStamp], leftAnchorEndIndex: Int, rightAnchorStartIndex: Int) -> [WordTimeStamp] {
        // Return the real timestamps strictly between the two anchors; these shape the gap.
        if rightAnchorStartIndex - leftAnchorEndIndex <= 1 {
            return []
        }
        return Array( timeStamps[(leftAnchorEndIndex + 1)..<rightAnchorStartIndex] )
    }
    
    
    private func buildInterpolatedTimeStamps(wordsSlice: ArraySlice<String>, startTime: Double, endTime: Double, template: WordTimeStamp) -> [WordTimeStamp] {
        let n = wordsSlice.count
        if n == 0 { return [] }
        if n == 1 {
            let ts = template.with( token:wordsSlice.first!, start: startTime, end: endTime, isInterpolated: true)
            return [ts]
        }
        var output: [WordTimeStamp] = []
        let total = endTime - startTime
        let step  = total / Double(n)
        var s = startTime
        
        for token in wordsSlice {
            let e = s + step
            let ts = template.with( token: token, start: s, end:e , isInterpolated: true)
            output.append(ts)
            s = e
        }
        return output
    }
    
    private func fillGapUsingWaypoints(
        words: [String],
        wordsStartIndex: Int,
        wordsEndIndexExclusive: Int,
        startBoundTime: Double,
        endBoundTime: Double,
        waypoints: [WordTimeStamp],
        template: WordTimeStamp
    ) -> [WordTimeStamp] {
        // Use any timestamps between anchors as "waypoints" to preserve timing shape.
        // If waypoint count equals word count, map 1:1. Otherwise, distribute words
        // across sub-intervals (duration-weighted) and interpolate inside each sub-interval.
        if wordsStartIndex >= wordsEndIndexExclusive { return [] }

        let wordsSlice = words[wordsStartIndex..<wordsEndIndexExclusive]
        if waypoints.isEmpty {
            return buildInterpolatedTimeStamps(wordsSlice: wordsSlice, startTime: startBoundTime, endTime: endBoundTime, template: template)
        }

        if waypoints.count == wordsSlice.count {
            return Array(waypoints.prefix(wordsSlice.count))
        }

        // Build sub-interval bounds: [startBound] + waypoint.ends + [endBound]
        var bounds: [Double] = [startBoundTime]
        bounds.append(contentsOf: waypoints.map { $0.end })
        bounds.append(endBoundTime)

        // Allocate words to each sub-interval proportional to its duration (largest remainder).
        let intervals = bounds.count - 1
        let totalDuration = max(1e-9, (0..<intervals).reduce(0.0) { acc, i in acc + (bounds[i+1] - bounds[i]) })

        let totalWords = wordsSlice.count
        let idealTakes: [Double] = (0..<intervals).map { i in
            Double(totalWords) * max(0.0, bounds[i+1] - bounds[i]) / totalDuration
        }
        var takes: [Int] = idealTakes.map { Int(floor($0)) }
        let remaining = totalWords - takes.reduce(0, +)
        if remaining > 0 {
            let order = idealTakes.enumerated()
                .sorted { (a, b) in
                    (a.element - Double(takes[a.offset])) > (b.element - Double(takes[b.offset]))
                }
            var r = remaining
            var i = 0
            let m = order.count
            while r > 0 && m > 0 {
                takes[order[i].offset] += 1
                r -= 1
                i += 1
                if i == m { i = 0 } // wrap for multiple passes
            }
        }
        // Emit interpolated spans within each sub-interval.
        var output: [WordTimeStamp] = []
        output.reserveCapacity(wordsSlice.count)
        var wordIterator = wordsSlice.makeIterator()
        for i in 0..<intervals {
            let s = bounds[i]
            let e = bounds[i+1]
            let k = takes[i]
            if k == 0 { continue }
            var chunk: [String] = []
            for _ in 0..<k {
                if let tok = wordIterator.next() { chunk.append(tok) }
            }
            let chunkSlice = chunk[chunk.startIndex..<chunk.endIndex]
            output.append(contentsOf: buildInterpolatedTimeStamps(wordsSlice: chunkSlice, startTime: s, endTime: e, template: template))
        }
        
        return output
    }

    
    private func reallocateHeadByPeelingFirstAnchor(
        firstAnchor: Anchor,
        timeStamps: [WordTimeStamp],
        words: [String],
        sentenceRange: SentenceRange
    ) -> [WordTimeStamp] {
        let anchorMergedTimeStamp = firstAnchor.mergedTimeStamp
        let reallocationStartTime = min(sentenceRange.start, anchorMergedTimeStamp.start)
        let rawReallocationEndTime = anchorMergedTimeStamp.end

        let headWordCount = firstAnchor.wordIndex
        let totalItemCount = headWordCount + 1
        //if totalItemCount <= 0 || reallocationEndTime <= reallocationStartTime { return [anchorMergedTimeStamp] }
        
        if totalItemCount <= 0 {
            return [anchorMergedTimeStamp]
        }
        let reallocationEndTime = max(rawReallocationEndTime, reallocationStartTime)

        let totalDuration = reallocationEndTime - reallocationStartTime
        let endTimeForHeadWords = reallocationStartTime + totalDuration * (Double(headWordCount) / Double(totalItemCount))

        
        let headWordsSlice = words[0..<firstAnchor.wordIndex]
        var outputTimeStamps = buildInterpolatedTimeStamps(
            wordsSlice: headWordsSlice,
            startTime: reallocationStartTime,
            endTime: endTimeForHeadWords,
            template: anchorMergedTimeStamp
        )

        let anchorTimeStamp = anchorMergedTimeStamp.with(
            start: endTimeForHeadWords,
            end: reallocationEndTime,
            isInterpolated: true
        )
        outputTimeStamps.append(anchorTimeStamp)

        return outputTimeStamps
    }
    
    
    // Redistribute a zero-width (or negative) middle gap by peeling the last-emitted left anchor
    // and re-slicing the closed interval [left.start, right.end] across:
    // [leftAnchorToken] + gap words (via buildInterpolatedTimeStamps) + [rightAnchorToken].
    private func redistributeZeroWidthMiddle(
        alignedTimeStamps: inout [WordTimeStamp],
        leftAnchor: Anchor,
        rightAnchor: Anchor,
        words: [String]
    ) -> WordTimeStamp {
        guard var lastEmittedLeft = alignedTimeStamps.popLast() else {
            return rightAnchor.mergedTimeStamp
        }

        let leftMerged  = leftAnchor.mergedTimeStamp
        let rightMerged = rightAnchor.mergedTimeStamp
        

        let reallocationStartTime = leftMerged.start
        let rawReallocationEndTime   = rightMerged.end

        if rawReallocationEndTime <= reallocationStartTime {
            logger.log(.debug, "reallocationEnd < reallocationStart in redistribute Middle --- zero durations for all")
        }

        let reallocationEndTime = max(rawReallocationEndTime, reallocationStartTime)

        let gapWordStartIndex = leftAnchor.wordIndex + 1
        let gapWordEndIndex   = rightAnchor.wordIndex
        let gapWordCount      = max(0, gapWordEndIndex - gapWordStartIndex)
        let totalItemCount    = gapWordCount + 2

        let totalDuration     = reallocationEndTime - reallocationStartTime
        let durationPerItem   = totalDuration / Double(totalItemCount)

        // 1) Left anchor retimed to first slot
        let leftEndTime = reallocationStartTime + durationPerItem
        lastEmittedLeft = lastEmittedLeft.with(
            token: leftMerged.token,
            end: leftEndTime,
            endOffset: lastEmittedLeft.endOffset,
            isInterpolated: true
        )
        alignedTimeStamps.append(lastEmittedLeft)

        // 2) Gap words across the middle slots using buildInterpolatedTimeStamps
        if gapWordCount > 0 {
            let middleStartTime = leftEndTime
            let middleEndTime   = reallocationStartTime + Double(gapWordCount + 1) * durationPerItem
            let gapWordsSlice   = words[gapWordStartIndex..<gapWordEndIndex]
            let interpolated    = buildInterpolatedTimeStamps(
                wordsSlice: gapWordsSlice,
                startTime: middleStartTime,
                endTime: middleEndTime,
                template: lastEmittedLeft
            )
            alignedTimeStamps.append(contentsOf: interpolated)

            // 3) Right anchor gets the final slot
            return rightMerged.with(start: middleEndTime, end: reallocationEndTime, isInterpolated: true)
        }
        return rightMerged.with(start: leftEndTime, end: reallocationEndTime, isInterpolated: true)
    }
    
    /*
    private func reallocateTailByPeelingLast(
        alignedTimeStamps: inout [WordTimeStamp],
        toWords: [String],
        allTimeStamps: [WordTimeStamp],
        //overrideStartTime: Double? = nil,
        //overrideTemplate: WordTimeStamp? = nil
    ) {
        guard alignedTimeStamps.count < toWords.count else { return }
        let padEndTime = allTimeStamps.last!.end

        /*
        if let s = overrideStartTime, let t = overrideTemplate, s < padEndTime {
            let wordsSlice = toWords[alignedTimeStamps.count..<toWords.count]
            let redistributed = buildInterpolatedTimeStamps(
                wordsSlice: wordsSlice,
                startTime: s,
                endTime: padEndTime,
                template: t
            )
            alignedTimeStamps.append(contentsOf: redistributed)
            return
        }*/

        var baseWordIndex = alignedTimeStamps.count
        var reallocationStartTime = allTimeStamps.first!.start
        var templateTimeStamp = allTimeStamps.first!

        if baseWordIndex > 0 {
            var last = alignedTimeStamps.removeLast()
            baseWordIndex -= 1
            reallocationStartTime = last.start
            templateTimeStamp = last

            while reallocationStartTime >= padEndTime && baseWordIndex > 0 {
                last = alignedTimeStamps.removeLast()
                baseWordIndex -= 1
                reallocationStartTime = last.start
                templateTimeStamp = last
            }
            if reallocationStartTime >= padEndTime {
                reallocationStartTime = allTimeStamps.first!.start
                templateTimeStamp = allTimeStamps.first!
            }
        }

        let wordsSlice = toWords[baseWordIndex..<toWords.count]
        let redistributed = buildInterpolatedTimeStamps(
            wordsSlice: wordsSlice,
            startTime: reallocationStartTime,
            endTime: padEndTime,
            template: templateTimeStamp
        )
        alignedTimeStamps.append(contentsOf: redistributed)
    }
     */
}
