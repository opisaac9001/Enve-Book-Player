//
//  FuzzySearch.swift
//
// SPDX-License-Identifier: MIT
//
// Original source Copyright (c) 2023 Shane Friedman
// Translated and modified Copyright (c) 2025 Rich Waters
//

import Foundation

extension String {
    func slice(from: Int, to: Int) -> String {
        let start = self.index(self.startIndex, offsetBy: from)
        let end = self.index(self.startIndex, offsetBy: to)
        return String(self[start..<end])
    }
    
    func substring(from: Int) -> String {
        let start = self.index(self.startIndex, offsetBy: from)
        return String(self[start...])
    }
}


struct Match {
    let start: Int
    let end: Int
    let dist: Int
}

struct ExpandResult {
    let score: Int
    let index: Int
}

struct FuzzySearcher {
    func findNearestMatch(needle: String, haystack: String, maxDist: Int) -> (match: String, index: Int)? {
        let candidates = levenshteinNgram(subsequence: needle, sequence: haystack, maxDist: maxDist)
        guard let nearest = candidates.min(by: { $0.dist < $1.dist }) else {
            return nil
        }
        let matchStr = haystack.slice(from: nearest.start, to: nearest.end)
        return (match: matchStr, index: nearest.start)
    }
}

extension FuzzySearcher {
    
    private func reverse(_ str: String, from: Int? = nil, to: Int = 0) -> String {
        let endIndex = from ?? str.count
        let startIdx = str.index(str.startIndex, offsetBy: to)
        let endIdx   = str.index(str.startIndex, offsetBy: endIndex)
        var chars = Array(str[startIdx..<endIdx])
        chars.reverse()
        return String(chars)
    }
    
    
    // Searches for all occurrences of `subsequence` within `sequence`
    // between offsets `startIndex` and `endIndex` (end exclusive).
    
    //Boyer–Moore–Horspool
    //
    private func searchExact( subsequence: String, in hay: [Character], startIndex: Int = 0, endIndex: Int? = nil) -> [Int] {
        let ned = Array(subsequence)
        let hCount = hay.count
        let nCount = ned.count
        let e = endIndex ?? hCount
        
        guard nCount > 0,
              startIndex >= 0,
              e <= hCount,
              nCount <= e - startIndex
        else { return [] }
        
        var skip = [Character: Int]()
        for i in 0..<nCount - 1 {
            skip[ned[i]] = nCount - i - 1
        }
        
        var results = [Int]()
        var i = startIndex
        while i <= e - nCount {
            var j = nCount - 1
            while j >= 0 && hay[i + j] == ned[j] {
                j -= 1
            }
            if j < 0 {
                results.append(i)
                i += 1
            } else {
                let shift = skip[hay[i + nCount - 1]] ?? nCount
                i += shift
            }
        }
        return results
    }
    
    // Attempts to “expand” a matching region on `sequence` to cover `subsequence` (or part of it),
    // returning an ExpandResult that contains a score (the Levenshtein distance) and an index (the expansion length).
    //
    private func expand(subsequence: String, sequence: String, maxDist: Int) -> ExpandResult? {
        let needle = Array(subsequence)
        let seq = Array(sequence)
        let n = needle.count
        if n == 0 { return ExpandResult(score: 0, index: 0) }
        
        var scores = Array(0...n)
        var minScore = n
        var minIndex = -1
        var maxGood = maxDist
        var rangeStart: Int? = 0
        var rangeEnd = n - 1
        
        for i in 0..<seq.count {
            let c0 = i + 1
            guard let start = rangeStart else { break }
            let end = min(n, rangeEnd + 1)
            
            var a = i
            var c = c0
            
            if c <= maxGood {
                rangeStart = 0
                rangeEnd = 0
            } else {
                rangeStart = nil
                rangeEnd = -1
            }
            
            for j in start..<end {
                let b = scores[j]
                let cost = needle[j] == seq[i] ? 0 : 1
                c = min(a + cost, min(b + 1, c + 1))
                scores[j] = c
                a = b
                
                if c <= maxGood {
                    if rangeStart == nil { rangeStart = j }
                    rangeEnd = max(rangeEnd, j + 1 + (maxGood - c))
                }
            }
            
            if rangeStart == nil { break }
            if end == n && c <= minScore {
                minScore = c
                minIndex = i
                if c < maxGood { maxGood = c }
            }
        }
        
        return minScore <= maxDist
        ? ExpandResult(score: minScore, index: minIndex + 1)
        : nil
    }
    
    // Implements the n-gram based fuzzy search.
    //Returns an array of Match results representing candidate matches.
    private func levenshteinNgram(subsequence: String, sequence: String, maxDist: Int, shortCircuit:(distance:Int, offset:Int,endOffset:Int)?=nil) -> [Match] {
        var matches: [Match] = []
        let subsequenceLength = subsequence.count
        let sequenceLength = sequence.count
        let hayArray = Array(sequence)
        
        let raw = Double(subsequenceLength) / Double(maxDist + 1)
        let ngramLength = Int(raw.rounded(.toNearestOrAwayFromZero))
        guard ngramLength > 0 else {
            fatalError("The subsequence length must be greater than maxDist")
        }
        
        var ngramStart = 0
        while ngramStart <= subsequenceLength - ngramLength {
            let ngramEnd = ngramStart + ngramLength
            let subsequenceBeforeReversed = reverse(subsequence, from: ngramStart)
            let subsequenceAfter = subsequence.substring(from: ngramEnd)
            
            let startIndex = max(0, ngramStart - maxDist)
            let endIndex = min(sequenceLength, sequenceLength - subsequenceLength + ngramEnd + maxDist)
            
            let ngram = subsequence.slice(from: ngramStart, to: ngramEnd)
            let exactMatches = searchExact(subsequence: ngram, in: hayArray, startIndex: startIndex, endIndex: endIndex)
            
            for index in exactMatches {
                let rightSliceStart = index + ngramLength
                let rightSliceEnd = index - ngramStart + subsequenceLength + maxDist
                if rightSliceStart > sequenceLength { continue }
                let rightSequence = sequence.slice(from: rightSliceStart, to: min(rightSliceEnd, sequenceLength))
                guard let rightMatch = expand(subsequence: subsequenceAfter, sequence: rightSequence, maxDist: maxDist) else {
                    continue
                }
                let distRight = rightMatch.score
                let rightExpandSize = rightMatch.index
                
                let leftSubsequenceReversed = subsequenceBeforeReversed
                let leftSliceFrom = max(0, index - ngramStart - (maxDist - distRight))
                let leftSequence = reverse(sequence, from: index, to: leftSliceFrom)
                guard let leftMatch = expand(subsequence: leftSubsequenceReversed, sequence: leftSequence, maxDist: maxDist - distRight) else {
                    continue
                }
                let distLeft = leftMatch.score
                let leftExpandSize = leftMatch.index
                let matchStart = index - leftExpandSize
                let matchEnd = index + ngramLength + rightExpandSize
                
                let dist = distLeft + distRight
                matches.append(Match(start: matchStart, end: matchEnd, dist: dist))
                if let shortCircuit = shortCircuit {
                    if( dist <= shortCircuit.distance && matchStart <= shortCircuit.offset  && (matchEnd >= (sequenceLength - shortCircuit.endOffset)) ) {
                        return matches
                    }
                }
            }
            
            ngramStart += ngramLength
        }
        
        return matches
    }
}


struct NGramIndex {
    let ngramSize: Int
    let index: [String: [Int]]    // n-gram → list of character offsets

    init(transcript: String, ngramSize: Int = 5) {
        self.ngramSize = ngramSize
        var idx = [String: [Int]]()
        let words = Self.words(from: transcript)
        guard ngramSize > 0, words.count >= ngramSize else {
            self.index = idx
            return
        }
        var charOffsets = [Int]()
        var offset = 0
        for w in words {
            charOffsets.append(offset)
            offset += w.count + 1
        }
        for i in 0...(words.count - ngramSize) {
            let gram = words[i..<i+ngramSize].joined(separator: " ")
            idx[gram, default: []].append(charOffsets[i])
        }
        self.index = idx
    }
    func candidates(for chunk: String) -> [Int] {
        let words = Self.words(from: chunk)
        guard ngramSize > 0, words.count >= ngramSize else {
            return []
        }

        var hits = Set<Int>()
        for i in 0...(words.count - ngramSize) {
            let gram = words[i..<i+ngramSize].joined(separator: " ")
            if let offs = index[gram] {
                hits.formUnion(offs)
            }
        }
        return Array(hits).sorted()
    }
    
    static func words( from chunk:String ) -> [String] {
        let words = chunk
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return words
    }
}
