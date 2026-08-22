//
// NLTokenizer+Extensions.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//

import NaturalLanguage

fileprivate let emDash = "—"



struct Tokenizer {
    func tokenizeSentences(text: String) -> [String] {
        if text.isEmpty {
            return []
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences = [String]()
        
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            let sentence = text[tokenRange]
            if !sentence.trim().isEmpty {
                sentences.append(String(sentence))
            }
            return true
        }
        
        return sentences
    }
    
    func tokenizeWords(text input: String) -> [String] {
        if input.isEmpty { return [] }

        @inline(__always)
        func isSeparatorScalar(_ s: Unicode.Scalar) -> Bool {
            if s.properties.isWhitespace { return true }

            switch s.value {
            case 0x2014: return true // —
            case 0x002C: return true // ,
            case 0x003B: return true // ;
            case 0x0021: return true // !
            case 0x003F: return true // ?
            case 0x007C: return true // |
            default: return false
            }
        }

        var tokens: [String] = []
        var from = input.startIndex
        var i = from

        while i < input.endIndex {
            let ch = input[i]

            var isSep = false
            for s in ch.unicodeScalars {
                if isSeparatorScalar(s) {
                    isSep = true
                    break
                }
            }

            if !isSep {
                i = input.index(after: i)
                continue
            }

            let head = input[from..<i]
            let delim = input[i...i]   // single-Character slice

            if !head.isEmpty {
                var t = String(head)
                t.append(contentsOf: delim)
                tokens.append(t)
            } else if tokens.isEmpty {
                tokens.append(String(delim))
            } else {
                tokens[tokens.index(before: tokens.endIndex)].append(contentsOf: delim)
            }

            i = input.index(after: i)
            from = i
        }

        let tail = input[from...]
        if !tail.isEmpty { tokens.append(String(tail)) }

        return coalescePunctOnlyWords(tokens).filter { !$0.trimmed().isEmpty }
    }
    
    /*
    func tokenizeWords(text: String) -> [String] {
        //return tokenizeWords( text, separator: /[\s—,.;:!?|]/ )
        return tokenizeWords( text, separator: /[\s—,;!?|]/ )
    }
    
    func tokenizeWords(_ input: String, separator: Regex<Substring>) -> [String] {
        if input.isEmpty { return [] }
        
        var tokens: [String] = []
        var from = input.startIndex

        for m in input.matches(of: separator) {
            let r = m.range
            let head = input[from..<r.lowerBound]
            let delim = input[r]

            if !head.isEmpty {
                var t = String(head)
                t.append(contentsOf: delim)
                tokens.append(t)
                from = r.upperBound
                continue
            }

            if tokens.isEmpty {
                tokens.append(String(delim))
            } else {
                tokens[tokens.index(before: tokens.endIndex)].append(contentsOf: delim)
            }
            from = r.upperBound
        }

        let tail = input[from...]
        if !tail.isEmpty { tokens.append(String(tail)) }
        
        let merged = coalescePunctOnlyWords(tokens).filter { !$0.trimmed().isEmpty }
        return merged
    }*/
    
    func tokenizePhrases(text: String) -> [String] {
        if text.isEmpty { return [] }
        
        let phraseSeparators = [",", ":", ";", emDash]
        let minWordsForPhrase = 2
        
        let sentences = tokenizeSentences(text: text)
        let phrases = sentences.flatMap { (sentence) -> [String] in
            let sentenceWords = tokenizeWords(text: sentence)
            var sentencePhrases:[String] = []
            var phraseWords:[String] = []
            for (index,word) in sentenceWords.enumerated() {
                guard !word.isEmpty else { continue }
                
                phraseWords.append(word)
                
                guard phraseWords.count >= minWordsForPhrase else {
                    continue
                }
                guard index < sentenceWords.count - 2 else {
                    continue
                }

                if phraseSeparators.contains( String(word.trimmed().last!) ) {
                    sentencePhrases.append( phraseWords.joined() )
                    phraseWords = []
                }
            }
            if !phraseWords.isEmpty {
                sentencePhrases.append(phraseWords.joined())
            }
            return sentencePhrases
        }
        return phrases
    }

    func coalescePunctOnlyWords(_ words: [String]) -> [String] {
        var out: [String] = []
        var leading = ""

        for w in words {
            if w.isAllWhiteSpaceOrPunct {
                if out.isEmpty {
                    leading += w
                } else {
                    out[out.count - 1] += w
                }
                continue
            }

            if !leading.isEmpty {
                out.append(leading + w)
                leading.removeAll(keepingCapacity: true)
            } else {
                out.append(w)
            }
        }

        if !leading.isEmpty { out.append(leading) }
        return out
    }
    
}
