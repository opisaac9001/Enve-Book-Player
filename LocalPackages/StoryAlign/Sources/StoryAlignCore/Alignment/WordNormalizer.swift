//
// WordNormalizer.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//

import Foundation


class WordNormalizer {
    static let emDash = "—"
    let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        return f
    }()
    
    let punctuationMap:[Character: Character] = [
        "“": "\"",
        "”": "\"",
        "„": "\"",
        "‟": "\"",
        "«": "\"",
        "»": "\"",
        "〝": "\"",
        "〞": "\"",
        "‘": "'",
        "’": "'",
        "‚": "'",
        "‛": "'",
        "‐": "-", // Unicode Hyphen
        "‑": "-", // Non-breaking Hyphen
        "‒": "-", // Figure Dash  -- used for phone numbers
        "–": "-", // En Dash -- used for ranges 10-47

        
        // These break up tokens -- so don't map them to hyphens
        // Em-Dash == —
        // "—": "—", // Em Dash -- used to separate thoughts - almost like a period
        //
        "―": WordNormalizer.emDash.first!, // Horizontal Bar -- map to EM Dash
        
        //"…": "...",
        "‹": "<",
        "›": ">"
    ]

    func normalizePunctuation(_ input: String) -> String {
        let nuChars = input.map {
            if let nuChar = punctuationMap[$0] {
                return nuChar
            }
            return $0
        }
        return String(nuChars).replacingOccurrences(of: "--", with: Self.emDash)
    }

    private var spelledNumberCache = [String:String]()

    func normalizedWord(_ word: String) -> (String, Int) {
        let leading  = word.prefix { $0.isWhitespace }
        let trailingChars = word.reversed().prefix { $0.isPunctuation || $0.isWhitespace }
        let trailing = String(trailingChars.reversed())
        let core = String( word.dropFirst(leading.count).dropLast(trailing.count) )
        
        let numberValue:Int? = {
            let allDigits = core.allSatisfy { $0.isNumber }
            if allDigits {
                return Int(core)
            }
            if isRomanNumeral(core) {
                return intFromRomanNumeral(core)
            }
            return nil
        }()
        
        
        guard let i = numberValue else {
            let parts = core.split(separator: ".", omittingEmptySubsequences: false)
            let leadsWithDot = parts.first?.isEmpty == true
            let hasDots = parts.count >= 2
            let nonEmptyNumeric = parts.dropFirst(leadsWithDot ? 1 : 0).allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            let hasInternalEmpties = parts.dropFirst().contains { $0.isEmpty }
            if hasDots, nonEmptyNumeric, !hasInternalEmpties {
                func spell(_ s: Substring) -> String {
                    let key = String(s)
                    if let cached = spelledNumberCache[key] { return cached }
                    let val = Int(key)!
                    let out = numberFormatter.string(from: NSNumber(value: val))!
                    spelledNumberCache[key] = out
                    return out
                }
                let spelledParts = parts.dropFirst(leadsWithDot ? 1 : 0).map { spell($0) }
                let body = spelledParts.joined(separator: " point ")
                let joined = leadsWithDot ? "point \(body)" : body
                if trailing.contains("%") {
                    let rest = trailing.replacingOccurrences(of: "%", with: "")
                    let newWord = "\(leading)\(joined) percent\(rest)"
                    return (newWord, newWord.count - word.count)
                }
                let newWord = "\(leading)\(joined)\(trailing)"
                return (newWord, newWord.count - word.count)
            }
            let afterLeading = word.dropFirst(leading.count)
            if afterLeading.first == "%", afterLeading.dropFirst().allSatisfy({ $0.isPunctuation }) {
                let rest = String(afterLeading.dropFirst())
                let newWord = "\(leading)percent\(rest)"
                return (newWord, newWord.count - word.count)
            }
            let wordWithNormalizedPunct = normalizePunctuation(word)
            return (wordWithNormalizedPunct, 0)
        }
        
        /*
        guard let i = numberValue else {
            let afterLeading = word.dropFirst(leading.count)
            if afterLeading.first == "%", afterLeading.dropFirst().allSatisfy({ $0.isPunctuation }) {
                let rest = String(afterLeading.dropFirst())
                let newWord = "\(leading)percent\(rest)"
                return (newWord, newWord.count - word.count)
            }
            let wordWithNormalizedPunct = normalizePunctuation(word)
            return(wordWithNormalizedPunct,0)
        }*/
        //if i > 10000 {
        //return (normalizePunctuation(word),0)
        //}

        let key = String(core)
        let spelled = spelledNumberCache[key]
        ?? {
            let s = numberFormatter.string(from: NSNumber(value: i))!
            spelledNumberCache[key] = s
            return s
        }()
        if trailing.contains("%") {
            let rest = trailing.replacingOccurrences(of: "%", with: "")
            let newWord = "\(leading)\(spelled) percent\(rest)"
            return (newWord, newWord.count - word.count)
        }
        
        let newWord = "\(leading)\(spelled)\(trailing)"
        return (newWord, newWord.count - word.count)
    }
    
    
    func normalizeWordsInSentence(_ sentence: String) -> String {
        //let tokens = Tokenizer().tokenize(text: sentence)
        let tokens = Tokenizer().tokenizeWords(text: sentence)
        let words = tokens.map {
            normalizedWord($0).0
        }
        let out = words.joined()
        return out 
        /*
        let re = try! NSRegularExpression(pattern: #"(\S+)|(\s+)"#)
        let ns = sentence as NSString
        var out = ""
        re.enumerateMatches(in: sentence, range: NSRange(location:0, length:ns.length)) { m, _, _ in
            guard let m = m else { return }
            let run = ns.substring(with: m.range)
            if run.first!.isWhitespace {
                out += run
            } else {
                out += normalizedWord(run).0
            }
        }
        return out
         */
    }
    
    //func isRomanNumeral(_ core:String ) -> Bool {
    //core.range(of: "^[IVXLCDM]{2,}$", options: .regularExpression) != nil
    //}
    
    func isRomanNumeral(_ core: String) -> Bool {
        if core.count < 2 { return false }

        for u in core.utf8 {
            switch u {
            case 73, 86, 88, 76, 67, 68, 77: // I V X L C D M
                continue
            default:
                return false
            }
        }
        return true
    }
    
    func intFromRomanNumeral(_ s:String ) -> Int? {
        let vals: [Character:Int] = [
            "I":1, "V":5,  "X":10, "L":50,
            "C":100, "D":500, "M":1000
        ]
        var total = 0
        var prev = 0
        for c in s.uppercased().reversed() {
            guard let v = vals[c] else { return nil }
            if v < prev {
                total -= v
            } else {
                total += v
                prev = v
            }
        }
        return total
    }
}
