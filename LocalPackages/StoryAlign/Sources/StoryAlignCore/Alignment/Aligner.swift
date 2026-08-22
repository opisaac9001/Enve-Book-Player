//
// Aligner.swift
// SPDX-License-Identifier: MIT
//
// Copyright (c) 2023 Shane Friedman
// Copyright (c) 2025 Rich Waters
//

import Foundation

typealias FoundMatch =  (index: Int, match: String, matchType:SentenceMatchType)

fileprivate let OFFSET_SEARCH_WINDOW_SIZE = 5000

final class UsedOffets: @unchecked Sendable {
    private let lock = NSLock()
    private var offsets: [(start: Int, end: Int)]

    init(count: Int) {
        offsets = Array(0..<count).map { _ in (start: 0, end: 0) }
    }

    func markUsed(index: Int, start: Int, end: Int) {
        lock.withLock { offsets[index] = (start: start, end: end) }
    }

    func startsAfter(index: Int) -> Int {
        lock.withLock {
            var i = index - 1
            while i >= 0 {
                let offset = offsets[i]
                if offset.end != 0 { return offset.end }
                if offset.start != 0 { return offset.start }
                i -= 1
            }
            return 0
        }
    }

    func endsBefore(index: Int) -> Int {
        lock.withLock {
            var i = index + 1
            while i < offsets.count {
                let offset = offsets[i]
                if offset.start != 0 { return offset.start }
                i += 1
            }
            return 0
        }
    }
}

public struct Aligner : AlignmentSessionProviding, Sendable {
    public let session:AlignmentSession
    private let fuzzySearcher = FuzzySearcher()
    

    public init(session: AlignmentSession) {
        self.session = session
    }
    
    public func align( ebook:EpubDocument, audioBook:AudioBook, rawTranscriptions:[RawTranscription] ) async throws -> [AlignedChapter] {
        try Task.checkCancellation()


        let manifestItems = try selectManifestItemsToAlign(in: ebook )
        let expansionScope = sessionConfig.granularityExpansion?.scope
        let (largeTokenItems,smallTokenItems):( [EpubManifestItem], [EpubManifestItem]? ) = try {
            guard let expansionScope else {
                return (manifestItems,nil)
            }
            let retokenizedManifestItems = try manifestItems.map { item in
                guard let xmlData = item.xmlData else {
                    return item
                }
                let xmlText = String( data: xmlData, encoding: .utf8) ?? ""
                let sentences = try EpubXhtmlTextParser.getXHtmlSentences(from: xmlText, granularity: expansionScope)
                let retokenizedItem = item.with(xhtmlSentences:sentences)
                return retokenizedItem
            }
            return( retokenizedManifestItems, manifestItems )
        }()
        
        let largeSentenceCount = largeTokenItems.reduce(0) { $0 + ($1.xhtmlSentences.count) }
        let smallSentenceCount = smallTokenItems?.reduce(0) { $0 + ($1.xhtmlSentences.count) }
        let ebookSentenceCount = largeSentenceCount + (smallSentenceCount ?? 0)

        //let ebookSentenceCount = manifestItems.reduce(0) { $0 + ($1.xhtmlSentences.count) }
        
        progressTracker.updateProgress(for: .align, event:.start, total: ebookSentenceCount)
        
        let rawSegs = rawTranscriptions.flatMap(\.segments)
        logger.log(.debug, "Raw segments" )
        rawSegs.enumerated().forEach { (index,seg) in
            logger.log(.debug, "Segment \(index): \(seg.description)", indentLevel: 1)
        }
        //let transcriber = TranscriberFactory.transcriber(session: session)
        let transcriber = try session.transcriberFactory.transcriber(session: session)
        let transcriptions = try rawTranscriptions.map { try transcriber.buildTranscription(from: $0) }
        
        //let allChapterSentences = ebook.manifest.flatMap { $0.xhtmlSentences }
        let allChapterSentences = largeTokenItems.flatMap { $0.xhtmlSentences }
        let longestSentenceLen = allChapterSentences.map { $0.count }.max()!
        let avgSentenceLen = Int( allChapterSentences.map { Double($0.count) }.average() )
        
        let fullTranscription = Transcription.concatTranscriptions(transcriptions, maxSentenceLen: longestSentenceLen*2, meanSentenceLen: avgSentenceLen)

        let transcribedWordCount = fullTranscription.transcription
            .split(whereSeparator: \.isWhitespace)
            .count
        if transcribedWordCount < 50 {
            throw StoryAlignError("Transcription produced only \(transcribedWordCount) word\(transcribedWordCount == 1 ? "" : "s"), which isn't enough to align this audiobook. The audio may be silent, music-only, in an unsupported language, or the file may be incomplete or corrupted. Try a different audiobook file or check that on-device speech recognition is enabled for your language in Settings → General → Language & Region.")
        }

        let transcriptionNgramIndex = NGramIndex(transcript: fullTranscription.transcription, ngramSize: 6)
        logger.log(.debug, "Transcription timeline Hasdups \(fullTranscription.wordTimeline.hasDuplicateConsecutiveSpans())" )
        logger.log(.debug, "Transcription timeline hasOverlaps \(fullTranscription.wordTimeline.hasOverlaps)" )
        
        //let refined = try await align(manifestItems: manifestItems, fullTranscription: fullTranscription, transcriptionNgramIndex: transcriptionNgramIndex)
        let refined = try await align(manifestItems: largeTokenItems, fullTranscription: fullTranscription, transcriptionNgramIndex: transcriptionNgramIndex)

        if !sessionConfig.granularity.useWordTokenizer {
            guard let smallTokenItems else {
                progressTracker.updateProgress(for: .align, event: .end)
                return refined
            }
            
            let phraseChapters = try await align(manifestItems: smallTokenItems, fullTranscription: fullTranscription, transcriptionNgramIndex: transcriptionNgramIndex)
            let combinedChapters = refined.enumerated().map { (index,largeItemChapter) in
                let phraseChapter = phraseChapters[index]
                let combinedChapter = phraseChapter.with( alignedSentences:largeItemChapter.alignedSentences, alignedWords:phraseChapter.alignedSentences)
                return combinedChapter
            }
            progressTracker.updateProgress(for: .align, event: .end)
            return combinedChapters
        }

        progressTracker.updateProgress(for: .align, event: .end)

        let totalWordCount = refined.reduce(0) { $0 + $1.alignedSentencesWordCount }
        let wordMultiplier = expansionScope?.useWordTokenizer == true ? 2 : 1
        progressTracker.updateProgress(for: .alignWords, event:.start, total: totalWordCount * wordMultiplier)
        
        let wordAlignedChapters = try await {
            let wordAligner = WordAligner(session: session)
            guard let expansion = sessionConfig.granularityExpansion,
                  let scope = expansion.scope,
                  scope.useWordTokenizer else {
                return try await wordAligner.alignWords(in: refined, granularity:sessionConfig.granularity)
            }
            
            let sentenceChapters = try await wordAligner.alignWords(in:refined, granularity: scope)
            let wordChapters = try await wordAligner.alignWords( in:refined, granularity:sessionConfig.granularity)
            
            let combinedChapters = (0..<refined.count).map {
                let refinedChapter = refined[$0]
                let wordChapter = wordChapters[$0]
                let sentenceChapter = sentenceChapters[$0]
                let combinedChapter = refinedChapter.with( alignedSentences:sentenceChapter.alignedWords, alignedWords:wordChapter.alignedWords)
                return combinedChapter
            }
            return combinedChapters
        }()
        
        // Need to do this so misalignments don't cause epubcheck to fail
        let refinedWordAlignedChapters = wordAlignedChapters.map {
            let nuSentences = expandEmptySentenceRanges(alignedSentences: $0.alignedWords, segments:fullTranscription.segments).0
            let nuAlignedItem = $0.with(alignedWords: nuSentences)
            return nuAlignedItem
        }
        
        progressTracker.updateProgress(for: .alignWords, event: .end)
        
        return refinedWordAlignedChapters
    }
    
    func align( manifestItems: [EpubManifestItem], fullTranscription: Transcription , transcriptionNgramIndex:NGramIndex ) async throws -> [AlignedChapter] {
        try Task.checkCancellation()

        guard let lastItem = manifestItems.reversed().first( where: { $0.spineItemIndex >= 0 } ) else {
            return []
        }
        let usedTranscriptionOffsets = UsedOffets(count: lastItem.spineItemIndex+1)

        let nThreads = sessionConfig.concurrency
        let firstPassAlignments:[AlignedChapter] = try await manifestItems.asyncCompactMap(concurrency: nThreads) { (manifestItem) -> AlignedChapter? in
            guard let alignedItem = try align(manifestItem: manifestItem, withTranscription: fullTranscription, usedOffsets: usedTranscriptionOffsets, transcriptionNGramIndex: transcriptionNgramIndex ) else {
                return nil
            }
            
            usedTranscriptionOffsets.markUsed(index: manifestItem.spineItemIndex, start: alignedItem.transcriptionStartOffset ?? 0, end: alignedItem.transcriptionEndOffset ?? 0)
            return alignedItem
        }
            .sorted { $0.manifestItem.spineItemIndex < $1.manifestItem.spineItemIndex }
        

        try Task.checkCancellation()


        
        // This gives another try at chapters that were skipped because they couldn't be found with the course ngramIndex. This tries again with the finer search, but it can be faster since the window is much smaller as the usedOffsets is filled in now.
        let secondPassAlignedItems = try firstPassAlignments.map { alignedItem in
            guard alignedItem.isEmpty else { return alignedItem }
           
            let manifestItem = alignedItem.manifestItem
            guard let nuItem = try align(manifestItem: manifestItem, withTranscription: fullTranscription, usedOffsets: usedTranscriptionOffsets, transcriptionNGramIndex: nil ) else {
                progressTracker.updateProgress(for: .align, increment: manifestItem.xhtmlSentences.count)
                return alignedItem
            }
            if nuItem.isEmpty {
                progressTracker.updateProgress(for: .align, increment: manifestItem.xhtmlSentences.count)
                return alignedItem
            }
            usedTranscriptionOffsets.markUsed(index: manifestItem.spineItemIndex, start: nuItem.transcriptionStartOffset ?? 0, end: nuItem.transcriptionEndOffset ?? 0)
            return nuItem
        }
            .sorted { $0.manifestItem.spineItemIndex < $1.manifestItem.spineItemIndex }

        try Task.checkCancellation()
        
        // Final pass
        // This looks for cases where chapterStart was too far into the chapter. It then tries to align those sentences starting from the end of the previous chapter. This can correct the missed alignments better than interpolation. Except for the case where there's stuff in the transcription in between chapters.
        var lastAlignedSentence:AlignedSentence? = nil
        let alignedItems = try secondPassAlignedItems.map { alignedItem in
            guard let firstAlignedSentence = alignedItem.alignedSentences.first else {
                return alignedItem
            }
            guard firstAlignedSentence.sentenceRange.timeStamps.count > 0 else {
                logger.log( .warn, "Internal error -- no time stamps for first aligned sentence in \(alignedItem)" )
                return alignedItem
            }
            defer {
                lastAlignedSentence = alignedItem.alignedSentences.last!
            }
            guard firstAlignedSentence.sentenceId != 0 else {
                return alignedItem
            }

            let firstSentenceStartOffset = firstAlignedSentence.sentenceRange.timeStamps.first!.startOffset
            let gap = firstSentenceStartOffset - (lastAlignedSentence?.sentenceRange.timeStamps.last!.endOffset ?? 0)
            guard gap > 0 else {
                return alignedItem
            }
            
            var startTransOffset = firstSentenceStartOffset-gap
            if firstAlignedSentence.sentenceRange.audioFile.filePath != lastAlignedSentence?.sentenceRange.audioFile.filePath {
                let audioFilePath = firstAlignedSentence.sentenceRange.audioFile.filePath
                let startTsIndex = lastAlignedSentence?.sentenceRange.timeStamps.last!.index ?? 0
                if let firstTsForAudioFile = fullTranscription.wordTimeline[startTsIndex...].first(where:{ $0.audioFile.filePath == audioFilePath}) {
                    startTransOffset = firstTsForAudioFile.startOffset
                }
            }

            let chapterSentences = Array(alignedItem.manifestItem.xhtmlSentences.prefix(firstAlignedSentence.sentenceId))
            if chapterSentences.isEmpty {
                return alignedItem
            }
            
            //let normalizedChapterSentences = try normalize(sentences: Array(chapterSentences) )
            let (alignedSentences, _, _ ) = try alignSentences( manifestItemName:alignedItem.manifestItem.name, chapterStartSentence: 0, xhtmlSentences: chapterSentences, transcription: fullTranscription, startingTransOffset: startTransOffset )
            guard alignedSentences.isEmpty == false else {
                return alignedItem
            }
            let nuSentences = alignedSentences + alignedItem.alignedSentences
            let nuAlignedItem = alignedItem.with(alignedSentences: nuSentences)
            return nuAlignedItem
        }
        
        let refined = try finalize(alignedItems: alignedItems, transcription: fullTranscription)
        return refined
    }
    
    func selectManifestItemsToAlign( in epub:EpubDocument ) throws -> [EpubManifestItem] {
        let bodyMatterHrefs = (epub.nav?.landmarks.bodymatterHrefs ?? []).map { $0.hrefWithoutFragment }
        let backMatterHrefs = (epub.nav?.landmarks.backmatterHrefs ?? []).map { $0.hrefWithoutFragment }
        
        let sortedManifest = epub.spineOrderedManifest
        let startManifestItem:EpubManifestItem? = {
            guard let startManifestItemId = sessionConfig.startManifestItemId else {
                return nil
            }
            let retItem = sortedManifest.first { $0.id == startManifestItemId }
            if retItem == nil {
                logger.log( .warn, "Couldn't find start chapter:\(startManifestItemId)" )
            }
            return retItem
        }()
        let endManifestItem:EpubManifestItem? = {
            guard let endManifestItemId = sessionConfig.endManifestItemId else {
                return nil
            }
            let  retItem = sortedManifest.first { $0.id == endManifestItemId }
            if retItem == nil {
                logger.log( .warn, "Couldn't find end chapter:\(endManifestItemId)" )
            }
            return retItem
        }()
        
        
        var inBodyMatter = bodyMatterHrefs.isEmpty && startManifestItem == nil
        var foundExplicitEnd = false
        let navDir = URL(filePath: epub.nav?.tocFileHref ?? "").deletingLastPathComponent().path()
        var manifestItems = sortedManifest.filter { manifestItem in
            if foundExplicitEnd {
                return false
            }
            let relPath = {
                let manifestHrefUrl = URL(filePath:manifestItem.href)
                guard manifestHrefUrl.deletingLastPathComponent().path() == navDir else {
                    return ""
                }
                return manifestHrefUrl.lastPathComponent
            }()
            
            if let startManifestItem {
                if manifestItem.id == startManifestItem.id {
                    inBodyMatter = true
                }
            }
            else if bodyMatterHrefs.contains(manifestItem.href) || bodyMatterHrefs.contains(relPath) {
                inBodyMatter = true
            }
            
            var include = inBodyMatter

            if let endManifestItem {
                if manifestItem.id == endManifestItem.id {
                    // endManifestItem is inclusive so include it if in bodymatter
                    inBodyMatter = false
                    foundExplicitEnd = true
                }
            }
            else {
                if backMatterHrefs.contains(manifestItem.href) || backMatterHrefs.contains(relPath) {
                    //backmatter is exclusive so don't include it
                    include = false
                    inBodyMatter = false
                }
            }

            return include
        }
        if manifestItems.isEmpty && !bodyMatterHrefs.isEmpty && !inBodyMatter {
            logger.log(.warn, "Couldn't find bodymatter: \(bodyMatterHrefs.first!)")
            manifestItems = sortedManifest
        }
        return manifestItems
    }
}

extension Aligner {

    //func align( manifestItem:EpubManifestItem, withTranscription transcription:Transcription, startsAfterOffset:Int, endsBeforeOffset:Int, transcriptionNGramIndex:NGramIndex? ) throws -> AlignedChapter? {
    func align( manifestItem:EpubManifestItem, withTranscription transcription:Transcription, usedOffsets:UsedOffets, transcriptionNGramIndex:NGramIndex? ) throws -> AlignedChapter? {

        logger.log(.info, "Aligning \(manifestItem.name)")

        let transcriptionTxt = transcription.transcription
        let normalizedXhtmlSentences = try normalize(sentences: manifestItem.xhtmlSentences)
        
        if normalizedXhtmlSentences.isEmpty {
            logger.log(.info, "\(manifestItem.id) has no text; skipping")
            progressTracker.updateProgress(for: .align, increment: manifestItem.xhtmlSentences.count)
            return nil
        }
        
        if normalizedXhtmlSentences.count < 2 {
            if (normalizedXhtmlSentences.first ?? "").split(separator: " ").count < 4 {
                logger.log(.info, "\(manifestItem.id) has fewer than four words; skipping")
                progressTracker.updateProgress(for: .align, increment: manifestItem.xhtmlSentences.count)
                return nil
            }
        }

        //let endsBeforeOffset = usedOffsets.endsBefore(index: manifestItem.spineItemIndex)
        //guard let (startSentence, startTranscriptionOffset) = findBestOffset(manifestItemId:manifestItem.id, epubChapterSentences: chapterSentences, transcriptionText: transcriptionTxt, startsAfterOffset: startsAfterOffset, endsBeforeOffset: endsBeforeOffset) else {
        let  offsetInfo = {
            guard let transcriptionNGramIndex else {
                let startsAfterOffset = usedOffsets.startsAfter(index: manifestItem.spineItemIndex)
                let endsBeforeOffset = usedOffsets.endsBefore(index: manifestItem.spineItemIndex)
                return findBestOffset(manifestItemId:manifestItem.id, epubChapterSentences: normalizedXhtmlSentences, transcriptionText: transcriptionTxt, startsAfterOffset: startsAfterOffset, endsBeforeOffset: endsBeforeOffset)
            }
            //return findBestOffset2(manifestItemId:manifestItem.id, epubChapterSentences: chapterSentences, transcription:transcription, startsAfterOffset: startsAfterOffset, endsBeforeOffset: endsBeforeOffset, index: transcriptionNGramIndex)
            return findBestOffset2(manifestItem:manifestItem, epubChapterSentences: normalizedXhtmlSentences, transcription:transcription, usedOffsets:usedOffsets, index: transcriptionNGramIndex)
        }()
        
        
        guard let (startSentence, startTranscriptionOffset) = offsetInfo else {
           logger.log(.info, "Couldn't find matching transcription for \(manifestItem.id)")
           return AlignedChapter(manifestItem:manifestItem)
       }

        usedOffsets.markUsed(index: manifestItem.spineItemIndex, start: startTranscriptionOffset, end: 0)

        let (alignedSentences, skippedSentences, endTranscriptionOffset ) = try alignSentences( manifestItemName:manifestItem.name, chapterStartSentence: startSentence, xhtmlSentences: manifestItem.xhtmlSentences, transcription: transcription, startingTransOffset: startTranscriptionOffset )

        logger.log(.debug, "Found chapter starrt for \(manifestItem.id) at \(startTranscriptionOffset)")
        logger.log(.debug, "Found end for \(manifestItem.id) at \(endTranscriptionOffset)")
        logger.log( .debug, "Manifest item start text: \(manifestItem.startTxt.collapseWhiteSpace())\n----\n")
        logger.log( .debug, "Transcription start text: \(transcriptionTxt.safeSubstring(from: startTranscriptionOffset , length:128))\n====\n\n" )
        logger.log( .debug, "Manifest item end text: \(manifestItem.endTxt.collapseWhiteSpace())")
        logger.log( .debug, "Transcription end text: \(transcriptionTxt.safeSubstring(to: endTranscriptionOffset , length:128).collapseWhiteSpace())" )

        let alignedChapter = AlignedChapter(manifestItem: manifestItem, transcriptionStartOffset: startTranscriptionOffset, transcriptionEndOffset: endTranscriptionOffset, alignedSentences: alignedSentences, skippedSentences:skippedSentences, rebuiltSentences: [] )

        logger.log(.info, "Completed alignment of \(manifestItem.id)")

        
        return alignedChapter
    }

    
    public func finalize(alignedItems: [AlignedChapter], transcription:Transcription) throws -> [AlignedChapter] {
        var lastSentenceRange:SentenceRange? = nil

        let validAlignedChapters = dropOutOfOrderEarly(alignedItems: alignedItems)
        
        let refinedAlignedItems = try validAlignedChapters.enumerated().map { (index,alignedItem) in
            if alignedItem.isEmpty || alignedItem.alignedSentences.isEmpty {
                return alignedItem
            }


            let doRefine = { (alignedItem:AlignedChapter ) -> AlignedChapter in
                //let chapterSentences = try normalize(sentences: alignedItem.manifestItem.xhtmlSentences)
                let (refined,rebuilt) = try refine(alignSentences: alignedItem.alignedSentences, lastSentenceRange:lastSentenceRange, transcription:transcription, xhtmlSentences: alignedItem.manifestItem.xhtmlSentences)
                lastSentenceRange = refined.last?.sentenceRange
                return alignedItem.with(alignedSentences: refined, rebuiltSentences: rebuilt)
            }
            
            
            let firstSentence = alignedItem.alignedSentences.first!
            if firstSentence.sentenceId != 0 {
                return try doRefine(alignedItem)
            }
            
            guard let last = lastSentenceRange else {
                firstSentence.sentenceRange.start = 0
                return try doRefine(alignedItem)
            }
            
            if firstSentence.sentenceRange.audioFile.filePath == last.audioFile.filePath  {
                last.end = firstSentence.sentenceRange.start
                return try doRefine(alignedItem)
            }
            last.end = last.audioFile.duration
            firstSentence.sentenceRange.start = 0
            return try doRefine(alignedItem)
        }
        lastSentenceRange?.end = lastSentenceRange?.audioFile.duration ?? 0
        
        return refinedAlignedItems
    }
    
    
    public func firstGoodChapterIndex( alignedItems: [AlignedChapter], minRunForGood:Int, minInversionTimeDiff: Double ) -> Int? {
        if alignedItems.isEmpty {
            return nil
        }
        if minRunForGood <= 1  {
            return 0
        }

        func firstRange(_ item: AlignedChapter) -> SentenceRange? {
            item.alignedSentences.first?.sentenceRange
        }

        func inOrder(prev: SentenceRange, next: SentenceRange) -> Bool {
            let prevPath = prev.audioFile.filePath.path()
            let nextPath = next.audioFile.filePath.path()

            if nextPath > prevPath { return true }
            if nextPath < prevPath { return false }

            return (next.start - prev.start) >= minInversionTimeDiff
        }

        var runStartIndex: Int? = nil
        var runCount = 0
        var lastRange: SentenceRange? = nil

        for (i, item) in alignedItems.enumerated() {
            guard !item.alignedSentences.isEmpty else {
                continue
            }
            let cur = item.alignedSentences[0].sentenceRange
            if let last = lastRange, inOrder(prev: last, next: cur) {
                runCount += 1
            } else {
                runStartIndex = i
                runCount = 1
            }

            lastRange = cur

            if runCount >= minRunForGood {
                return runStartIndex
            }
        }

        return nil
    }
    
    func dropOutOfOrderEarly( alignedItems:[AlignedChapter] ) -> [AlignedChapter] {
        let minInversionTimeDiff = -300.0  // allow inversions of up to 5 minutes. We're just trying to catch the big stuff
        let minRunForGood = min( alignedItems.count, 2 )
        let firstValidChapterIndex = firstGoodChapterIndex(alignedItems: alignedItems, minRunForGood: minRunForGood, minInversionTimeDiff: minInversionTimeDiff)
        let validAlignedChapters = alignedItems.enumerated().map { (index,alignedItem) in
            if index >= (firstValidChapterIndex ?? 0) {
                return alignedItem
            }
            if alignedItem.alignedSentences.isEmpty {
                return alignedItem
            }
            let startChapterMsg = {
                var i = index + 1
                while i < alignedItems.count {
                    let nextItem = alignedItems[i]
                    if !nextItem.alignedSentences.isEmpty {
                        return "Configuring start chapter to '\(nextItem.manifestItem.name)' might remove this warning."
                    }
                    i += 1
                }
                return ""
            }()
            logger.log( .warn, "Dropping misaligned chapter: \(alignedItem.manifestItem.name) \(startChapterMsg)".trimmed() )
            let nuSkipped = alignedItem.alignedSentences.map {
                SkippedSentence(chapterSentence: $0.xhtmlSentence, chapterSentenceId: $0.sentenceId)
            }
            return alignedItem.with( alignedSentences: [], skippedSentences:( alignedItem.skippedSentences + nuSkipped ) )
        }
        return validAlignedChapters
    }
    
    func normalize( sentences:[String] ) throws  -> [String] {
        let wordNormalizer = WordNormalizer()
        let chapterSentences = sentences.map { wordNormalizer.normalizeWordsInSentence($0).collapseWhiteSpace().trimmed() }
        if chapterSentences.count != sentences.count {
            logger.log( .debug, "Some sentences were empty after normalization. This should not happen.")
        }
        return chapterSentences
    }

}


private extension Aligner {
    private func findBestOffset(manifestItemId:String,  epubChapterSentences: [String], transcriptionText: String, startsAfterOffset:Int, endsBeforeOffset:Int ) -> (startSentence: Int, transcriptionOffset: Int)? {
        let lastMatchOffset = startsAfterOffset

        var offset = lastMatchOffset + 1
        let textCount = transcriptionText.count
        while offset < textCount {
            var startSentence = 0
            let endOffset = min( max(offset + OFFSET_SEARCH_WINDOW_SIZE, endsBeforeOffset), textCount )

            if offset > endOffset {
                logger.log(.debug, "Can we still get here?")
                return nil
            }
            let startIndex = transcriptionText.index(transcriptionText.startIndex, offsetBy: offset)
            let endIndex = transcriptionText.index(transcriptionText.startIndex, offsetBy: endOffset)
            let transcriptionTextSlice = String(transcriptionText[startIndex..<endIndex])
            while startSentence < epubChapterSentences.count {
                let sliceEnd = min(startSentence + 6, epubChapterSentences.count)
                let queryString = epubChapterSentences[startSentence..<sliceEnd].joined(separator: " ")
                let loweredQuery = queryString.lowercased()
                let loweredTextSlice = transcriptionTextSlice.lowercased()
                let maxDistance = max(Int(Double(queryString.count) * 0.1), 1)
                if let firstMatch = fuzzySearcher.findNearestMatch(needle: loweredQuery, haystack: loweredTextSlice, maxDist: maxDistance) {
                    let offset = (firstMatch.index + offset) % textCount
                    logger.log(.debug, "\(manifestItemId): Found best offset \(offset) traversed:\(offset - lastMatchOffset)")
                    
                    return (startSentence: startSentence, transcriptionOffset: offset)
                }
                
                startSentence += 3
                //startSentence += 1
            }
            
            offset += min( textCount - offset, OFFSET_SEARCH_WINDOW_SIZE / 2)
        }
        
        logger.log( .debug, "\(manifestItemId):   No chapter offset found. traversed:\(offset - lastMatchOffset)")
        
        return nil
    }
    
    private func findBestOffset2( manifestItem: EpubManifestItem, epubChapterSentences: [String], transcription: Transcription, usedOffsets:UsedOffets, index: NGramIndex ) -> (startSentence: Int, transcriptionOffset: Int)? {
        let manifestItemId = manifestItem.id
        let transcriptionText = transcription.transcription
        let textCount = transcriptionText.count
        
        for chapterSentenceIndex in stride(from: 0, to: epubChapterSentences.count, by: 3) {
            let sliceEnd = min(chapterSentenceIndex + 6, epubChapterSentences.count)
            let chunk = epubChapterSentences[chapterSentenceIndex..<sliceEnd]
                .joined(separator: " ")

            let loweredNeedle = chunk.lowercased()
            let maxDist = max(Int(Double(loweredNeedle.count) * 0.1), 1)
            let windowSize = min( loweredNeedle.count*3, OFFSET_SEARCH_WINDOW_SIZE)
            
            let endsBeforeOffset = usedOffsets.endsBefore(index: manifestItem.spineItemIndex)
            let endOffset = endsBeforeOffset == 0 ? textCount : endsBeforeOffset
            let startsAfterOffset = usedOffsets.startsAfter(index: manifestItem.spineItemIndex)


            let allCandidates = index.candidates(for: chunk)
            let candidates:[Int] = allCandidates.pairs().compactMap { (prev,candidate) in
                if candidate > endOffset || candidate < startsAfterOffset {
                    return nil
                }
                guard let lastCandidate=prev else {
                    return candidate
                }
                if lastCandidate > 0 && (candidate + loweredNeedle.count + maxDist) < (lastCandidate+windowSize) {
                    return nil
                }
                return candidate
            }
            
            logger.log( .debug,  "manifoldItemId:\(manifestItemId) findChapterOffsetRough: WindowSize \(windowSize)  candidatesCount:\(candidates.count) chunkSize:\(chunk.count) sentenceIndex:\(chapterSentenceIndex)", indentLevel: 1)
            
            var candidateIndex = 0
            for candidate in candidates {
                let windowEnd = min(candidate + windowSize, textCount)
                let start = transcriptionText.index(transcriptionText.startIndex, offsetBy: candidate )
                let end = transcriptionText.index( transcriptionText.startIndex, offsetBy: windowEnd )
                let slice = transcriptionText[start..<end]
                let loweredHay = slice.lowercased()
                
                guard let match = fuzzySearcher.findNearestMatch( needle: loweredNeedle, haystack: loweredHay, maxDist: maxDist ) else {
                    candidateIndex += 1
                    continue
                }
                        
                let found = (candidate + match.index) % textCount
                logger.log( .debug, "manifoldItemId:\(manifestItemId) findChapterOffsetRough: found at candidateIndex:\(candidateIndex), offset:\(found-startsAfterOffset) sentence:\(chapterSentenceIndex)")
                let (fineStart, fineEnd) = {
                    guard let sentenceIndex = transcription.indexOfSentence(containingOffset: found) else {
                        let fineWindowSize = OFFSET_SEARCH_WINDOW_SIZE
                        let fineStart = max(0, found - fineWindowSize / 2)
                        let fineEnd = min(found + fineWindowSize / 2, textCount)
                        return( fineStart, fineEnd )
                    }
                    let fineStartSentence = max(0, sentenceIndex-6)
                    let fineEndSentence = min(sentenceIndex+6, transcription.sentences.count-1)
                    return (transcription.sentencesOffsets[fineStartSentence].startIndex, transcription.sentencesOffsets[fineEndSentence].endIndex )
                }()
                
                guard let (fineStartSentence, offset) = findBestOffset(manifestItemId: manifestItemId, epubChapterSentences: epubChapterSentences, transcriptionText: transcriptionText, startsAfterOffset: fineStart, endsBeforeOffset: fineEnd) else {
                    logger.log(.info, "Could not find best offset for \(manifestItemId) from index")
                    return( chapterSentenceIndex, found)
                }
                return (fineStartSentence, offset)
            }
        }
        return nil
    }
}

extension Aligner {

    func alignSentences( manifestItemName:String, chapterStartSentence: Int, xhtmlSentences: [String], transcription: Transcription, startingTransOffset: Int ) throws -> (alignedSentences: [AlignedSentence], skippedSentences:[SkippedSentence], transcriptionOffset: Int) {
        var alignedSentences: [AlignedSentence] = []
        var skippedSentences:[SkippedSentence] = []

        let transcriptionStartSentenceIndex = (transcription.indexOfSentence(containingOffset: startingTransOffset) ?? 0)
        let transcriptionSentenceOffsets = transcription.sentencesOffsets[transcriptionStartSentenceIndex]
        let midSentenceOffset = max(0, startingTransOffset - transcriptionSentenceOffsets.lowerBound)
        let firstTransSentence = transcription.sentences[transcriptionStartSentenceIndex].safeSubstring(from: midSentenceOffset)
        let otherTransSentences = transcription.sentences[transcriptionStartSentenceIndex+1 ..< transcription.sentences.count]
        let transcriptionSentences = ([firstTransSentence] + otherTransSentences).map { $0.lowercased() }
        var startSentenceEntry = chapterStartSentence
        
        
        let charactersToRemove: Set<Character> = [".", "-", "_", "(", ")", "[", "]", ",", "/", "?", "!", "@", "#", "$", "%", "^", "&", "*", "`", "~", ";", ":", "=", "'", "\"", "<", ">", "+", "ˌ", "ˈ", "“"]
        
        let isTooShort = { ( sentence: String ) -> Bool  in
            let cleaned = sentence.filter { !charactersToRemove.contains($0) }
            return cleaned.count <= 3
        }
        
        let filteredChapterSentences: [(Int, String)] = try xhtmlSentences.enumerated().filter { (index, sentence) in
            let normalizedSentence = try normalize(sentences:[sentence]).first!
            let cleaned = normalizedSentence.filter { !charactersToRemove.contains($0) }
            if cleaned.count == 0 {
            //if cleaned.count <= 3 {
            //if cleaned.count < 3 {
                if index < chapterStartSentence {
                    startSentenceEntry -= 1
                }
                let skippedSentence = SkippedSentence(chapterSentence: sentence, chapterSentenceId: index)
                skippedSentences.append(skippedSentence)
                return false
            }
            return true
        }

        let windowSize = 10
        var transcriptionWindowIndex = 0
        var transcriptionWindowOffset = 0
        var lastGoodTranscriptionWindow = 0
        var notFound = 0
        var sentenceIndex = startSentenceEntry
        var lastMatchEnd = startingTransOffset

        while sentenceIndex < filteredChapterSentences.count {
            try Task.checkCancellation()

            guard transcriptionWindowIndex < transcriptionSentences.count else {
                break
            }

            let (sentenceId, sentence) = filteredChapterSentences[sentenceIndex]
            let tooShort = isTooShort(sentence )
            let fullWindowList = Array(transcriptionSentences.dropFirst(transcriptionWindowIndex).prefix(windowSize))
            let safeRaw = fullWindowList.joined()
            let safeOffset = min(transcriptionWindowOffset, safeRaw.count)
            let transcriptionWindow = String(safeRaw.dropFirst(safeOffset))
            
            let normalizedSentence = try! normalize(sentences: [sentence]).first!
            let query = normalizedSentence.trimmed().collapseWhiteSpace().lowercased()

            let smallQuerySpecialCase = query.split(separator: " ").count <= 3 && query.count < 20
            let hardMaxWindowSize = smallQuerySpecialCase ? 3 :  windowSize

            let seeds = computeWindowSizes(forQuery: query, transcriptionSentences: transcriptionSentences, fromTransWindowIdx: transcriptionWindowIndex, transWindowOffset:transcriptionWindowOffset, hardMaxWindowSize: hardMaxWindowSize)
            

            var listUsed: [String] = []
            var foundMatch: (index: Int, match: String, matchType:SentenceMatchType)? = nil
            for ws in seeds {
                let candidateList = Array(transcriptionSentences.dropFirst(transcriptionWindowIndex).prefix(ws))
                let startIdx = min(transcriptionWindowIndex, transcriptionSentences.count)
                let rawSentences = Array(transcriptionSentences.dropFirst(startIdx).prefix(ws))
                let raw = rawSentences.joined()
                let safeDrop = min(transcriptionWindowOffset, raw.count)
                let haystack = String(raw.dropFirst(safeDrop))
                
                defer {
                    if let foundMatch {
                        logger.log(.debug, "Found match at index:\(foundMatch.index): type:\(foundMatch.matchType) queryLen:\(query.count) matchLen:\(foundMatch.match.count)" )
                        logger.log(.debug, "query:\(query)", indentLevel: 1 )
                        logger.log( .debug, "haystack:\(haystack)\n", indentLevel: 1)
                        listUsed = candidateList
                    }
                }
                
                // dynamic threshold
                let baseDist = max(Int(floor(0.25 * Double(query.count))), 1)
                let drift = transcriptionWindowIndex - lastGoodTranscriptionWindow
                let threshold = max(1, Int(Double(baseDist) / Double(drift + 1)))
                
                logger.log(.debug, "Seed:\(ws) Haystack size: \(haystack.count)")

                if haystack.starts(with: query) {
                    foundMatch = (0, query, .exact)
                    break
                }
                if haystack.starts(with: " \(query)") {
                    foundMatch = (1, query, .trimmedLeading)
                    break
                }

                if let range = rangeExactMatchIgnoringSurroundingPunctuation(in: haystack, query: query) {
                    let matched = String(haystack[range])
                    let offset  = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                    foundMatch = (offset, matched, .ignoringEndsPunctuation)
                    break
                }
                
                if let range = rangeExactMatchIgnoringAllPunctuation(in: haystack, query: query) {
                    let matched = String(haystack[range])
                    let offset  = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                    foundMatch = (offset, matched, .ignoringAllPunctuation)
                    break
                }

                if tooShort {
                    break;
                }
                
                if let m = fuzzySearcher.findNearestMatch(needle: query, haystack: haystack, maxDist: threshold) {
                    if m.index > 200 {
                        logger.log(.debug, "Far away match at index:\(m.index): type:\(m.match): query:\(query) haystack:\(haystack)" )
                    }
                    foundMatch = (m.index, m.match, .nearest)
                    break
                }
            }
            
            guard var firstMatch = foundMatch else {
                sentenceIndex += 1
                notFound += 1
                
                logger.log(.debug, "No match on try \(notFound) for chapterQuery \(query) transcriptionWindow: \(transcriptionWindow)")

                if tooShort || notFound == 3 || sentenceIndex == filteredChapterSentences.count {
                    let maxTransWindowTries = tooShort ? 2 : 30
                    
                    transcriptionWindowIndex += 1
                    if transcriptionWindowIndex == lastGoodTranscriptionWindow + maxTransWindowTries {
                        let skippedRange = filteredChapterSentences[(sentenceIndex - notFound)..<sentenceIndex]
                        logger.log(.debug, "TranscriptionWindoIndex hit limit:")
                        skippedSentences += skippedRange.map { (sentenceId,sentence) in
                            logger.log(.debug, "Skipped sentence -- hit transcriptionWindoIndex Limit: \(sentence)", indentLevel: 1)
                            return SkippedSentence( chapterSentence: sentence, chapterSentenceId: sentenceId /*, lastEndFoundOffset16: lastMatchEnd*/)
                        }
                        transcriptionWindowIndex = lastGoodTranscriptionWindow
                        notFound = 0
                        continue
                    }
                    sentenceIndex -= notFound
                    notFound = 0
                }
                continue
            }
            
            if notFound > 0 {
                let skipped = filteredChapterSentences[(sentenceIndex - notFound)..<sentenceIndex]
                skippedSentences += skipped.map { (sentenceId,sentence) in
                    logger.log(.debug, "Skipped sentence -- \(sentence)", indentLevel: 1)
                    return SkippedSentence( chapterSentence: sentence, chapterSentenceId: sentenceId /*, lastEndFoundOffset16: lastMatchEnd*/)
                }
            }
            notFound = 0


            let transcriptionOffset = transcriptionSentences[0..<transcriptionWindowIndex].joined().count
            let matchStartIndex =  firstMatch.index + transcriptionOffset + transcriptionWindowOffset + startingTransOffset
            guard let startResult = findStartTimestamp(matchStartIndex: matchStartIndex, transcription: transcription) else {
                sentenceIndex += 1
                continue
            }

            //var matchEndOffset = firstMatch.index + firstMatch.match.count + transcriptionOffset + transcriptionWindowOffset + startingTransOffset
            if firstMatch.match.last == " " && firstMatch.match.count > 1 {
                //matchEndOffset -= 1
                firstMatch.match.removeLast()
            }
            var start = startResult.start
            let audiofile = startResult.audioFile
            let endTimeStamp = findEndTimestamp(  fromStartTimeStamp:startResult, forMatch:firstMatch, transcription: transcription)
            let endValue = endTimeStamp.end

            var sharedTimeStamp = false
            // adjust previous ranges
            if !alignedSentences.isEmpty {
                var previousSentence = alignedSentences[alignedSentences.count - 1]
                let previous = previousSentence.sentenceRange
                if audiofile.filePath == previous.audioFile.filePath && previous.id == sentenceId - 1 {
                    if previous.timeStamps.first?.index == startResult.index && previous.timeStamps.last?.index == endTimeStamp.index {
                        logger.log( .debug, "Single timestap for multiple sentences: \(startResult.token)" )
                        previousSentence.sharedTimeStamp = true
                        alignedSentences[alignedSentences.count - 1] = previousSentence
                        sharedTimeStamp = true
                    }

                    let gap = start - previous.end
                    if gap > 0 {
                        
                        // Default to splitting the time between the 2 sentences equally.
                        start -= gap/2
                        let prevTimeStamp = previous.timeStamps.last!
                        
                        // If the sentences are in 2 different segments, use the segment information to split the gap
                        if prevTimeStamp.segmentIndex != startResult.segmentIndex {
                            let seg = transcription.segments[startResult.segmentIndex]
                            if seg.start < startResult.start && seg.start >= previous.end {
                                // set the start of this sentence to the start of the segment
                                start = seg.start
                            }
                            let prevEndSeg = transcription.segments[prevTimeStamp.segmentIndex]
                            if prevEndSeg.end < start  {
                                // If the previous segment ends before this one starts, backup the start to the end of the
                                // previous segment. This might not always be smart but I think in most cases it's better
                                // to move on asap.
                                start = prevEndSeg.end
                            }
                        }
                    }
                    previous.end = start
                }
                else if previous.id == sentenceId - 1 {
                    previous.end = previous.audioFile.duration
                    start = 0
                }
            }
            
            let timeStamps = Array(transcription.wordTimeline[startResult.index ... endTimeStamp.index])

            let sentenceRange = SentenceRange(id: sentenceId, start: start, end: endValue, audioFile: audiofile, timeStamps: timeStamps)
            let alignedSentence = AlignedSentence(xhtmlSentence: xhtmlSentences[sentenceId], sentenceId: sentenceId, sentenceRange: sentenceRange, matchText: foundMatch?.match, matchOffset: foundMatch?.index, matchType: foundMatch?.matchType, sharedTimeStamp: sharedTimeStamp)
            alignedSentences.append(alignedSentence)
            progressTracker.updateProgress(for: .align, increment: 1)

            notFound = 0
            //lastMatchEnd = matchEndOffset
            lastMatchEnd = endTimeStamp.endOffset
            let windowIndexResult = getWindowIndexFromOffset(window: listUsed, offset: firstMatch.index + firstMatch.match.count + transcriptionWindowOffset)
            transcriptionWindowIndex += windowIndexResult.index
            transcriptionWindowOffset = windowIndexResult.offset
            lastGoodTranscriptionWindow = transcriptionWindowIndex
            sentenceIndex += 1
        }
        
        if notFound > 0 {
            logger.log(.debug, "End of alignment loop: \(notFound) sentences not found")
            let skipped = filteredChapterSentences[(sentenceIndex - notFound)..<filteredChapterSentences.count]
            skippedSentences += skipped.map { (sentenceId,sentence) in
                logger.log(.debug, "Skipped sentence -- End of loop: \(sentence)", indentLevel: 1)
                return SkippedSentence( chapterSentence: sentence, chapterSentenceId: sentenceId /*, lastEndFoundOffset16: lastMatchEnd*/)
            }
        }
        
        return (alignedSentences, skippedSentences, lastMatchEnd)
    }
    
    func computeWindowSizes( forQuery query:String, transcriptionSentences:[String], fromTransWindowIdx:Int, transWindowOffset offs:Int, hardMaxWindowSize:Int) -> [Int] {
        
        let desiredSmallChars = Int( Double(query.count) * 1.5)
        let desiredMidChars = query.count * 3
        let desiredMaxChars = query.count * 7
                        
        let base = fromTransWindowIdx
        let computeOne = { (targetChars:Int, startIndex:Int) -> (windowCount: Int, charCount: Int)  in
            let overshootBias = 1.2
            
            var curLen = transcriptionSentences[base..<min(base + startIndex, transcriptionSentences.count)].reduce(0) { $0 + $1.count } - offs
            let endIndex = min(transcriptionSentences.count - base, hardMaxWindowSize)

            //var curLen = (remainingTransSentences.prefix(startIndex).reduce(0) { $0 + $1.count} ) - offs
            //let endIndex = min(remainingTransSentences.count, hardMaxWindowSize)
            
            for ws in (startIndex ..< endIndex) {
                //let s = remainingTransSentences[ws]
                //let sCount = s.count
                let sCount = transcriptionSentences[base + ws].count

                let newLen = curLen + sCount
                let newWs  = ws + 1
                
                let overshoot  = (newLen - targetChars)
                let undershoot = (targetChars - curLen)

                if newLen > targetChars {
                    if curLen <= query.count || Double(overshoot) <= Double(undershoot) * overshootBias {
                        curLen = newLen
                        return (windowCount:newWs, charCount: newLen)
                    }
                    return (windowCount: ws, charCount: curLen)
                }
                curLen = newLen
            }
            return (windowCount:endIndex, charCount: curLen)
        }

        let (minWS, minChars) = computeOne(desiredSmallChars, 0)
        var (midWS, midChars) = computeOne(desiredMidChars, minWS)
        var (maxWindowSize, maxChars) = computeOne(desiredMaxChars, midWS)

        if midWS <= minWS {
            midWS = (minWS + maxWindowSize) / 2
            if midWS <= minWS || midChars <= minChars {
                midWS = -1
            }
        }
        if  midWS >= maxWindowSize {
            midWS = -1
        }
        if maxWindowSize <= midWS || maxWindowSize <= minWS {
            maxWindowSize = -1
        }
        let seeds = [minWS, midWS, maxWindowSize].filter { $0 > 0 }
        
        logger.log(.debug, "computeWindowSizes: queryLen:\(query.count) --- desiredSmallChars \(desiredSmallChars) desiredMidChars \(desiredMidChars) desiredMaxChars \(desiredMaxChars) --  seeds: \(seeds) minChars \(minChars) midChars \(midChars) maxChars \(maxChars) ")
        
        return seeds
    }
    
    func rangeExactMatchIgnoringSurroundingPunctuation(in haystack: String, query: String) -> Range<String.Index>? {
        let endPunctCount = query.reversed().prefix { $0.isPunctuation }.count
        let leadPunctCount = query.prefix { $0.isPunctuation }.count
        let core = String(query.dropFirst(leadPunctCount).dropLast(endPunctCount))

        var h = haystack.startIndex
        while h < haystack.endIndex && (haystack[h].isPunctuation || haystack[h].isWhitespace) {
            h = haystack.index(after: h)
        }
        
        //let pattern = "^\\s*[[:punct:]]{0,\(leadPunctCount)}\(escapedCore)[[:punct:]]{0,\(endPunctCount)}"
        if !haystack[h...].hasPrefix(core) {
            return nil
        }
        let startHAfterPunct = h
        h = haystack.index(h, offsetBy: core.count)
        if h == haystack.endIndex {
            return startHAfterPunct..<h
        }
        
        //let maxH = haystack.index(h, offsetBy: endPunctCount)
        let maxH = haystack.index(h, offsetBy: endPunctCount, limitedBy: haystack.endIndex) ?? haystack.endIndex
        while h < haystack.endIndex && (haystack[h].isPunctuation && h < maxH ) {
            h = haystack.index(after: h)
        }
        
        return startHAfterPunct..<h
    }
    
    func stemPronounContraction(_ token: String) -> String {
        guard let i = token.firstIndex(where: { $0 == "'" || $0 == "’" }) else {
            return token
        }
        let left = String(token[..<i])
        let right = String(token[token.index(after: i)...])
        let pronouns: Set<String> = ["i","you","he","she","it","we","they"]
        let safeSuffixes: Set<String> = ["ll","re","ve","d","m"]
        if pronouns.contains(left.trimmed()) && safeSuffixes.contains(right.trimmed()) {
            return left.trimmed()
        }
        return token
    }
    
    func rangeExactMatchIgnoringAllPunctuation(in haystack: String, query: String) -> Range<String.Index>? {
        
        let queryWords = Tokenizer().tokenizeWords(text: query)
        let stemmedQuery = queryWords.map { stemPronounContraction($0) }.joined()
        let queryWithoutWhiteSpaceAndPunct = stemmedQuery.removeWhiteSpace().removePunctuation()
        //let queryWithoutWhiteSpaceAndPunct = query.removeWhiteSpace().removePunctuation()
        
        let haystackWords = Tokenizer().tokenizeWords(text: haystack)
        let stemmedHaystack = haystackWords.map { stemPronounContraction($0) }.joined()
        let haystackWithoutWhiteSpaceAndPunct = stemmedHaystack.removeWhiteSpace().removePunctuation()
        //let haystackWithoutWhiteSpaceAndPunct = haystack.removeWhiteSpace().removePunctuation()
        
        if queryWithoutWhiteSpaceAndPunct.isEmpty || haystackWithoutWhiteSpaceAndPunct.isEmpty {
            return nil
        }
        
        if !haystackWithoutWhiteSpaceAndPunct.starts(with: queryWithoutWhiteSpaceAndPunct) {
            return nil
        }
        
        var composedHayStack = ""
        var hayStackWordIndex = 0
        //let haystackWords = Tokenizer().tokenizeWords(text: haystack)
        for haystackWord in haystackWords {
            let stemmedHaystackWord = stemPronounContraction(haystackWord)
            //composedHayStack += haystackWord.removeWhiteSpace().removePunctuation()
            composedHayStack += stemmedHaystackWord.removeWhiteSpace().removePunctuation()
            if composedHayStack == queryWithoutWhiteSpaceAndPunct {
                break
            }
            hayStackWordIndex += 1
        }
        if composedHayStack != queryWithoutWhiteSpaceAndPunct {
            return nil
        }
        let words = haystackWords.prefix(hayStackWordIndex + 1)
        let joinedWords = words.joined()
        
        var startIndex = haystack.startIndex
        var leadingPunctCount = 0
        while startIndex < haystack.endIndex && (haystack[startIndex].isPunctuation || haystack[startIndex].isWhitespace) {
            startIndex = haystack.index(after: startIndex)
            leadingPunctCount += 1
        }
        if leadingPunctCount >= joinedWords.count {
            return nil
        }
        
        let endIndex = haystack.index(startIndex, offsetBy: joinedWords.count - leadingPunctCount)
        return startIndex..<endIndex
    }

    // Binary search helper: finds the first index in `timeline` where predicate is true.
    private func lowerBound(in timeline: [WordTimeStamp], where predicate: (WordTimeStamp) -> Bool) -> Int {
        var iters = 0
        var low = 0
        var high = timeline.count
        while low < high {
            iters += 1
            let mid = (low + high) / 2
            if predicate(timeline[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
    
    
    /*
    func findEndTimestamp(matchEndOffset: Int, transcription: Transcription) -> WordTimeStamp? {
        let timeline = transcription.wordTimeline
        let index = lowerBound(in: timeline) { $0.startOffset >= matchEndOffset }
        guard index > 0 else { return nil }
        return timeline[index - 1]
    }
    */
    
    func findEndTimestamp(  fromStartTimeStamp:WordTimeStamp, forMatch:FoundMatch, transcription: Transcription) -> WordTimeStamp {
        if forMatch.match.isEmpty {
            return fromStartTimeStamp
        }
        let matchEndOffset = fromStartTimeStamp.startOffset + forMatch.match.count - 1

        guard let endIndex = transcription.wordTimeline[fromStartTimeStamp.index... ].firstIndex(where: { $0.startOffset >= matchEndOffset }) else {
            return fromStartTimeStamp
        }
        let ts = (endIndex > 0 && endIndex > fromStartTimeStamp.index) ? transcription.wordTimeline[endIndex - 1] : fromStartTimeStamp

        if ts.index >= (transcription.wordTimeline.count - 1)  {
            return ts
        }
        
        let nextTx = transcription.wordTimeline[ts.index + 1]
        if nextTx.token.count > 4 || ts.tokenTypeGuess == .sentenceEnd || nextTx.tokenTypeGuess == .sentenceBegin {
            return ts
        }

        let full = transcription.transcription
        //let lo = full.index(full.startIndex, offsetBy: fromStartTimeStamp.startOffset)
        guard let lo = transcription.offsetToIndexMap[fromStartTimeStamp.startOffset] else {
            return ts
        }

        guard let hi = transcription.offsetToIndexMap[ts.endOffset+1] else {
            return ts
        }

        //let hi = full.index(lo, offsetBy: (ts.endOffset + 1 - fromStartTimeStamp.startOffset) )
        let tsSentence = full[lo..<hi].lowercased().trimmed()
        
        if tsSentence != forMatch.match.trimmed() {
            let mergedSentence = tsSentence+nextTx.token.lowercased().trimmed()
            if mergedSentence == forMatch.match.trimmed() {
                return nextTx
            }
        }

        return ts
    }

    

    func findStartTimestamp(matchStartIndex: Int, transcription: Transcription) -> WordTimeStamp? {
        let timeline = transcription.wordTimeline
        // Find the first entry where endOffsetUtf16 exceeds the matchStartIndex.
        
        // fails when token is 1 char ---
        let index = lowerBound(in: timeline) {
            $0.endOffset > matchStartIndex || ($0.token.count == 1 && $0.endOffset == matchStartIndex)
        }
        //let index = lowerBound(in: timeline) { $0.endOffset >= matchStartIndex }

        guard index < timeline.count else { return nil }
        let entry = timeline[index]
        return entry
    }


    func getWindowIndexFromOffset(window: [String], offset: Int) -> (index: Int, offset: Int) {
        var index = 0
        var remainingOffset = offset
        
        while index < window.count - 1 && remainingOffset >= window[index].count {
            remainingOffset -= window[index].count
            index += 1
        }
        
        return (index, remainingOffset)
    }
}


extension Aligner {
    var missingTimeStampToken:String {
        "[_MISSING_TIMESTAMP_IDENTIFIER_]"
    }
    
    func refine( alignSentences:[AlignedSentence], lastSentenceRange:SentenceRange?, transcription:Transcription, xhtmlSentences:[String] ) throws -> (all:[AlignedSentence], rebuilt:[AlignedSentence]) {
        let interpolated = try interpolateSentenceRanges(alignedSentences: alignSentences, xhtmlSentences: xhtmlSentences, lastSentenceRange: lastSentenceRange)
        let withOffsets = fillInOffsets(interpolated, using: transcription.wordTimeline)
        let (expanded, rebuilt) = expandEmptySentenceRanges(alignedSentences: withOffsets, segments: transcription.segments)
        return (expanded, rebuilt)
    }
    

    ///////////////
    ///
    func makeInterpolated( start: Double, duration:TimeInterval, startSentenceIndex:Int, count: Int,  xhtmlSentences:[String], audioFile: AudioFile) -> [AlignedSentence]  {
        
        let missingSentences = xhtmlSentences[startSentenceIndex ..< startSentenceIndex + count]
        let totalVlen = missingSentences.reduce(0.0) { $0 + $1.voiceLength }
        let secondsPerVlen = duration / totalVlen

        var lastStart = start
        let endIndex = startSentenceIndex + count
        let interpolatedSentences = (startSentenceIndex ..< endIndex).map {  index in
            let xhtmlSentence = index < xhtmlSentences.count ? xhtmlSentences[index] : ""
            let vlen = xhtmlSentence.voiceLength
            let interpolatedLength = count == 1 ? duration : vlen*secondsPerVlen
            
            let missingStart =  lastStart
            let missingEnd = missingStart + interpolatedLength
            lastStart = missingEnd
            let wordTimeStamp = WordTimeStamp(token: missingTimeStampToken, start: missingStart, end: missingEnd, audioFile: audioFile, transcriptionTokens: [], /*voiceLen: vlen,*/ segmentIndex: -1, tokenTypeGuess: .missing, isInterpolated: true)
            
            let newRange = SentenceRange(
                id: index,
                start: missingStart.roundToMs(),
                end: missingEnd.roundToMs(),
                audioFile: audioFile,
                timeStamps: [wordTimeStamp]
            )
            let nuSentence = AlignedSentence(xhtmlSentence:xhtmlSentence, sentenceId: index, sentenceRange: newRange, matchText: nil, matchOffset: nil, matchType: .interpolated)
            return nuSentence
        }

        return interpolatedSentences
    }
    
    func interpolateSentenceRanges(alignedSentences: [AlignedSentence], xhtmlSentences:[String], lastSentenceRange: SentenceRange?) throws -> [AlignedSentence] {

        if alignedSentences.isEmpty {
            return []
        }
        var interpolated: [AlignedSentence] = []
        var sentences = alignedSentences
        var firstAlignedSentence = sentences.removeFirst()
        let firstSentenceRange = firstAlignedSentence.sentenceRange
        
        if firstSentenceRange.id != 0 {
            let count = firstSentenceRange.id
            let crossesAudioBoundary = (lastSentenceRange == nil) || (firstSentenceRange.audioFile.filePath != lastSentenceRange?.audioFile.filePath)
            var diff = crossesAudioBoundary ? firstSentenceRange.start : firstSentenceRange.start - lastSentenceRange!.end
            
            if diff <= 0 {
                if crossesAudioBoundary {
                    // The storyTeller platform just ignores these. I'm not sure what the ramifications of trying to interpolate these are, but it seems to improve things a tiny bit in some cases.
                    if firstSentenceRange.start < 0.25 {
                        firstAlignedSentence.sharedTimeStamp = true
                        diff = 0.25
                        firstSentenceRange.start += diff
                    }
                    else {
                        diff = firstSentenceRange.start
                    }
                }
                else {
                    diff = 0.25
                    lastSentenceRange?.end = firstSentenceRange.start - diff
                }
            }
            
            let startPoint = crossesAudioBoundary ? 0.0 : lastSentenceRange!.end
            if diff > 0 {
                let interpolatedSentences = makeInterpolated(start: startPoint, duration: diff, startSentenceIndex: 0, count: count,xhtmlSentences: xhtmlSentences, audioFile: firstSentenceRange.audioFile)
                interpolated.append(contentsOf: interpolatedSentences)
                progressTracker.updateProgress(for: .align, increment: interpolatedSentences.count)
            }
        }
        interpolated.append(firstAlignedSentence)

        for alignedSentence in sentences {
            try Task.checkCancellation()

            let sentenceRange = alignedSentence.sentenceRange
            if interpolated.isEmpty {
                interpolated.append(alignedSentence)
                continue
            }
            
            let lastAlignedSentence = interpolated.last!
            let lastSentenceRange = lastAlignedSentence.sentenceRange
            let missingCount = sentenceRange.id - lastSentenceRange.id - 1
            
            if missingCount == 0 {
                interpolated.append(alignedSentence)
                continue
            }
            
            let crossesAudioBoundary = (sentenceRange.audioFile.filePath != lastSentenceRange.audioFile.filePath)
            var diff: Double = 0.0
            var gapAudioFile = sentenceRange.audioFile
            
            if crossesAudioBoundary {
                let (largestGap, audioFileFromGap) = getLargestGap(trailing: lastSentenceRange, leading: sentenceRange)
                diff = largestGap
                gapAudioFile = audioFileFromGap
            } else {
                diff = sentenceRange.start - lastSentenceRange.end
            }
            
            let currentSentence = alignedSentence
            
            if diff <= 0 {
                if crossesAudioBoundary {
                    let rangeLength = sentenceRange.end - sentenceRange.start
                    diff = (rangeLength < 0.5) ? rangeLength / 2.0 : 0.25
                    currentSentence.sentenceRange.start = diff.roundToMs()
                } else {
                    diff = 0.25
                    lastAlignedSentence.sentenceRange.end = (sentenceRange.start - diff).roundToMs()
                    interpolated[interpolated.count - 1] = lastAlignedSentence
                }
            }
            
            let startPoint = crossesAudioBoundary ? 0.0 : interpolated.last!.sentenceRange.end
            
            let interpolatedSentences = makeInterpolated(start: startPoint, duration:diff, startSentenceIndex:lastAlignedSentence.sentenceId + 1 , count: missingCount, xhtmlSentences: xhtmlSentences, audioFile: gapAudioFile)
            interpolated += interpolatedSentences
            
            progressTracker.updateProgress(for: .align, increment: interpolatedSentences.count)
            interpolated.append(currentSentence)
        }
        
        guard let last = interpolated.last else {
            return interpolated
        }
        
        let missingAtEnd = xhtmlSentences.count - last.sentenceId - 1
        guard missingAtEnd > 0 else {
            return interpolated
        }
        
        let interpolatedSentences = makeInterpolated(start:  last.sentenceRange.end, duration:0.25, startSentenceIndex:last.sentenceId + 1 , count: missingAtEnd, xhtmlSentences: xhtmlSentences, audioFile: last.sentenceRange.audioFile)
        interpolated += interpolatedSentences
        progressTracker.updateProgress(for: .align, increment: interpolatedSentences.count)
        
        return interpolated
    }
    
    func fillInOffsets(
        _ alignedSentences: [AlignedSentence],
        using timeline: [WordTimeStamp]
    ) -> [AlignedSentence] {
        if alignedSentences.isEmpty {
            return alignedSentences
        }
                
        var out = alignedSentences
        
        let realSentences = alignedSentences.filter {
            guard let timeStamp = $0.sentenceRange.timeStamps.first else {
                return false
            }
            return timeStamp.token != missingTimeStampToken
        }
        

        let assignedTimeStamps =  Set( realSentences.flatMap {
            $0.sentenceRange.timeStamps
        }.map { $0.index })
        
        
        let absoluteStart = max(0,alignedSentences.first!.sentenceRange.absoluteStart - 60)
        let absoluteEnd = alignedSentences.last!.sentenceRange.absoluteStart + 60
        let unassignedTimeStamps = timeline.filter {
            if $0.absoluteStart < absoluteStart  || $0.absoluteEnd > absoluteEnd {
                return false
            }
            return !assignedTimeStamps.contains( $0.index )
        }
        
        for i in 0..<out.count {
            let alignedSentence = out[i]
            let sentenceRange = alignedSentence.sentenceRange
            guard let wt = sentenceRange.timeStamps.first else {
                continue
            }
            if wt.token != missingTimeStampToken {
                continue
            }

            let filePath = sentenceRange.audioFile.filePath
            let windowStart = sentenceRange.start
            let windowEnd   = sentenceRange.end
            
            let realTimeStamps = unassignedTimeStamps.compactMap { (timeStamp) -> WordTimeStamp? in
                if timeStamp.audioFile.filePath != filePath {
                    return nil
                }
                if timeStamp.start < windowStart || timeStamp.end > windowEnd {
                    return nil
                }
                return timeStamp
            }

            if !realTimeStamps.isEmpty {
                sentenceRange.timeStamps = realTimeStamps
                out[i] = alignedSentence.with(sentenceRange: sentenceRange, matchType: .recoverable)
                continue
            }

            let prevEnd = (i > 0 ? out[i-1].sentenceRange.timeStamps.last?.endOffset : nil) ?? -1
            let nextStart = (i + 1 < out.count ? out[i+1].sentenceRange.timeStamps.first?.startOffset : nil) ?? prevEnd
            var fill = WordTimeStamp(
                token: missingTimeStampToken,
                start: wt.start,
                end: wt.end,
                audioFile: sentenceRange.audioFile,
                transcriptionTokens: [],
                //voiceLen: -1,
                segmentIndex: -1,
                tokenTypeGuess: .missing,
                isInterpolated: true
            )
            fill.startOffset = prevEnd + 1
            fill.endOffset = nextStart > 0 ? nextStart - 1 : prevEnd + 1
            sentenceRange.timeStamps = [fill]
            out[i] = alignedSentence.with(sentenceRange: sentenceRange, matchType: .interpolated)
        }
        
        return out
    }
    
    
    /**
     * Given two sentence ranges, find the trailing gap of the first
     * and the leading gap of the second, and return the larger gap
     * and corresponding audiofile.
     */
    func getLargestGap(trailing: SentenceRange, leading: SentenceRange) -> (Double, AudioFile) {
        let leadingGap = leading.start
        let duration = trailing.audioFile.duration
        let trailingGap = duration - trailing.end

        if trailingGap > leadingGap {
            return (trailingGap, trailing.audioFile)
        }
        return (leadingGap, leading.audioFile)
    }

    
}

extension Aligner {
    func rebuildIfNeeded( alignedSentence:AlignedSentence, alignedSentences:[AlignedSentence] ) -> [AlignedSentence] {
        
        let sentenceRange = alignedSentence.sentenceRange
        let chapterSentence = alignedSentence.xhtmlSentence
        let chapterSentenceIdOffset = (alignedSentences.first?.sentenceId ?? 0) - 0

        var rebuiltSentences:[AlignedSentence] = []
        
        if chapterSentence.isEmpty || chapterSentence.isAllWhiteSpaceOrPunct {
            if chapterSentence.count < 3 {
                //these are usually single " or a ". or similar. They should be pushed off the the next sentence or appended to previous one.
                logger.log(.debug, "FIXME \(chapterSentence)" )
            }
        }
        
        let words = chapterSentence.split(separator: " ")
        let duration = sentenceRange.duration
        let secondsPerWord = duration / Double(words.count)
        if !alignedSentence.sharedTimeStamp && secondsPerWord >= 0.1 {
            return []
        }
        
        if !alignedSentence.sharedTimeStamp && alignedSentence.matchType != .interpolated {
            return []
        }
        logger.log(.debug, "Suspicious \(alignedSentence)")

        let audioFile = alignedSentence.sentenceRange.audioFile.filePath
        guard let nextFoundSentence = ( alignedSentences.first { $0.sentenceRange.audioFile.filePath == audioFile && $0.sentenceId > alignedSentence.sentenceId && $0.matchType != .interpolated && !$0.sharedTimeStamp }) else {
            return []
        }
        guard let prevFoundSentence = (alignedSentences.reversed().first { $0.sentenceRange.audioFile.filePath == audioFile && $0.sentenceId < alignedSentence.sentenceId && ( ($0.matchType != .interpolated && !$0.sharedTimeStamp) || $0.sentenceId == 0)  }) else {
            return []
        }
        let durationToAllocate = nextFoundSentence.sentenceRange.end - prevFoundSentence.sentenceRange.start
        var lastEnd:TimeInterval = prevFoundSentence.sentenceRange.start
        
        let sentences = Array(alignedSentences[(prevFoundSentence.sentenceId-chapterSentenceIdOffset) ... (nextFoundSentence.sentenceId-chapterSentenceIdOffset)])
        
        let totalVlen = sentences.map { sentence in
            return ( sentence.xhtmlSentence + " " ).voiceLength
        } .reduce(0, +)
        let secondsPerVlen = durationToAllocate / totalVlen
        
        for sentence in sentences {
            defer {
                rebuiltSentences.append(sentence)
            }
            
            let vlen = (sentence.xhtmlSentence + " ").voiceLength
            let nuSentenceDuration:TimeInterval = Double(vlen) * secondsPerVlen
            sentence.sentenceRange.start = lastEnd.roundToMs()
            if sentence.sentenceId != nextFoundSentence.sentenceId {
                let newEnd:TimeInterval = lastEnd + nuSentenceDuration
                if newEnd > sentence.sentenceRange.start {
                    sentence.sentenceRange.end = newEnd.roundToMs()
                    lastEnd = newEnd
                }
            }
        }
        
        return rebuiltSentences
    }
    
    
    func expandEmptySentenceRanges(alignedSentences: [AlignedSentence], segments:[TranscriptionSegment]) -> (all:[AlignedSentence], rebuilt:[AlignedSentence]) {
        var expandedSentences = [AlignedSentence]()
        var rebuiltSentences = [AlignedSentence]()
        var rebuiltIds = Set<Int>()
        
        for alignedSentence in alignedSentences {
            let sentenceRange = alignedSentence.sentenceRange

            let rebuilt = rebuildIfNeeded(alignedSentence: alignedSentence, alignedSentences: alignedSentences)
            for r in rebuilt {
                if !rebuiltIds.contains(r.sentenceId) {
                    rebuiltSentences.append(r)
                    rebuiltIds.insert(r.sentenceId)
                }
            }
            
            if let previousSentence = expandedSentences.last {
                // If the previous range's end overlaps this sentence's start
                // and they belong to the same audio file, nudge the start.
                if previousSentence.sentenceRange.end > sentenceRange.start &&
                    previousSentence.sentenceRange.audioFile.filePath == sentenceRange.audioFile.filePath {
                    sentenceRange.start = previousSentence.sentenceRange.end
                }
                
                // If the end time is not greater than the start time, adjust it.
                if sentenceRange.end.roundToMs() <= sentenceRange.start.roundToMs() {
                    sentenceRange.end = sentenceRange.start.roundToMs() + 0.001
                    logger.log(.debug, "Expanded empty sentence range to avoid zero duration.")
                }
            }

            let nuSentence = alignedSentence.with(sentenceRange: sentenceRange, matchType: alignedSentence.matchType)
            expandedSentences.append(nuSentence)
        }
        
        return (expandedSentences,rebuiltSentences)
    }
}
