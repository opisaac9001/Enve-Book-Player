//
// AlignedChapter.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//

public struct AlignedChapter : Codable,Sendable {
    //let chapterIndex:Int
    let manifestItem:EpubManifestItem

    let transcriptionStartOffset:Int?
    let transcriptionEndOffset: Int?
    
    let alignedSentences:[AlignedSentence]
    let alignedWords:[AlignedSentence]

    let skippedSentences:[SkippedSentence]
    public let rebuiltSentences:[AlignedSentence]
    
    
    init(manifestItem: EpubManifestItem, transcriptionStartOffset: Int? = nil, transcriptionEndOffset: Int? = nil, alignedSentences: [AlignedSentence]=[], skippedSentences:[SkippedSentence]=[], rebuiltSentences: [AlignedSentence] = [], alignedWords:[AlignedSentence] = [] ) {
        self.manifestItem = manifestItem
        self.transcriptionStartOffset = transcriptionStartOffset
        self.transcriptionEndOffset = transcriptionEndOffset
        self.alignedSentences = alignedSentences
        self.skippedSentences = skippedSentences
        self.rebuiltSentences = rebuiltSentences
        self.alignedWords = alignedWords
    }

    var isEmpty:Bool {
        (self.alignedSentences.isEmpty && self.skippedSentences.isEmpty && self.transcriptionStartOffset == nil && self.rebuiltSentences.isEmpty && self.transcriptionEndOffset == nil )
    }
    
    var allSentenceRanges:[SentenceRange] {
        alignedSentences.map { $0.sentenceRange }
    }
    
    var alignedSentencesWordCount:Int {
        alignedSentences.reduce(0) { $0 + $1.xhtmlSentenceWords.count }
    }
    
    func with(manifestItem: EpubManifestItem? = nil,  transcriptionStartOffset: Int? = nil, transcriptionEndOffset: Int? = nil, alignedSentences: [AlignedSentence]? = nil, skippedSentences: [SkippedSentence]? = nil, rebuiltSentences:[AlignedSentence]?=nil, alignedWords: [AlignedSentence]? = nil ) -> AlignedChapter {

        return AlignedChapter(
            manifestItem:manifestItem ?? self.manifestItem,
            transcriptionStartOffset: transcriptionStartOffset ?? self.transcriptionStartOffset,
            transcriptionEndOffset: transcriptionEndOffset ?? self.transcriptionEndOffset,
            alignedSentences: alignedSentences ?? self.alignedSentences,
            skippedSentences: skippedSentences ?? self.skippedSentences,
            rebuiltSentences: rebuiltSentences ?? self.rebuiltSentences,
            alignedWords: alignedWords ?? self.alignedWords

        )
    }
}

extension AlignedChapter {
    var missingSentences:[String] {
        let chapterSentences = manifestItem.xhtmlSentences
        let skippedSentenceIds = Set(skippedSentences.map { $0.chapterSentenceId } )
        let alignedSentenceIds = Set( alignedSentences.map { $0.sentenceId} )
        let missingSentences = chapterSentences.enumerated().compactMap { (index,sentence) -> String? in
            if alignedSentenceIds.contains(index) {
                return nil
            }
            if skippedSentenceIds.contains( index ) {
                return nil
            }
            return sentence
        }
        return missingSentences
    }
     
    var isMissingChapter: Bool {
        if missingSentences.count > 0 && alignedSentences.count == 0 && skippedSentences.count == 0 {
            return true
        }
        return false
    }
    
    var interiorAlignedSentences:[AlignedSentence] {
        guard alignedSentences.count > 0 else {
            return []
        }
        return alignedSentences.filter { $0.sentenceId != 0 && $0.sentenceId != (manifestItem.xhtmlSentences.count-1) }
    }
}


