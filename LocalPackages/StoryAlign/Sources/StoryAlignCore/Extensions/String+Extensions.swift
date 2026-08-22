//
//  String+Extensions.swift
//  StoryAlign
//
//  Created by Rich Waters on 4/14/25.
//

import Foundation
import CryptoKit


public extension String {
    
    func contains(anyOf needles: [String], options: String.CompareOptions = []) -> Bool {
        if self.isEmpty || needles.isEmpty {
            return false
        }
        return needles.contains { self.range(of: $0, options: options) != nil }
    }
    
    // Can't use trim as name becuase it conflicts with SwiftSoup
    func trimmed() -> String {
        return trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func trimmingTrailingWhitespace() -> String {
        guard let idx = rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: .backwards)?.upperBound else { return "" }
        return String(self[..<idx])
    }
    
    func removeWhiteSpace() -> String {
        return replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
    }
    func removeNewlnes() -> String {
        return replacingOccurrences(of: "\n", with: "")
    }
    func removePunctuation() -> String {
        components(separatedBy: .punctuationCharacters).joined()
    }
    
    func collapseWhiteSpace() -> String {
        return replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
    
    func removingFragment() -> String {
        split(separator: "#", maxSplits: 1).first.map(String.init) ?? self
    }
    
    func safeSubstring(from start: Int, to end: Int) -> String {
        let lower = max(0, min(start, count))
        let upper = max(lower, min(end, count))
        
        let startIndex = index(startIndex, offsetBy: lower)
        let endIndex = index(startIndex, offsetBy: upper - lower)
        
        return String(self[startIndex..<endIndex])
    }
    
    
    func safeSubstring(from start: Int, length:Int? = nil) -> String {
        let len = length ?? self.count - start
        return safeSubstring(from: start, to: start+len)
    }
    func safeSubstring( to end:Int, length:Int) -> String {
        return safeSubstring(from: end-length, to: end)
    }
    
    var pathExtension: String {
        URL(fileURLWithPath: self).pathExtension
    }
    
    var isAllWhiteSpaceOrPunct:Bool {
        self.allSatisfy { $0.isWhitespace || $0.isPunctuation }
    }
    var endsWithWhiteSpace:Bool {
        guard let s = self.last else {
            return false
        }
        return s.isWhitespace
    }
    var startsWithWhiteSpace:Bool {
        let trimmed = drop { $0.isWhitespace }
        return trimmed.count < count
    }

    /*
    func escapingXMLEntities() -> String {
        var s = self
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\"", with: "&quot;")
        s = s.replacingOccurrences(of: "'", with: "&apos;")
        return s
    }*/
    func escapingXMLEntities() -> String {
        if !self.contains(where: { ch in
            ch == "&" || ch == "<" || ch == ">" || ch == "\"" || ch == "'"
        }) {
            return self
        }

        var out = String()
        out.reserveCapacity(self.utf8.count)

        for ch in self {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }

        return out
    }

    func chunked(minLength: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        var i = 0
        let n = count
        
        let characters = Array(self)
        while i < n {
            let char = characters[i]
            current.append(char)

            if current.count >= minLength && char.isWhitespace {
                let candidate = current
                current = ""
                if candidate.trimmed().isEmpty {
                    current = candidate
                    i += 1
                    continue
                }
                chunks.append(candidate)
            }

            i += 1
        }

        if !current.isEmpty {
            if current.trimmed().isEmpty {
                if !chunks.isEmpty {
                    chunks[chunks.count - 1] += current
                    return chunks
                }
                chunks.append(current)
                return chunks
            }
            
            chunks.append(current)
            return chunks
        }

        return chunks
    }
    
    var hrefWithoutFragment: String {
          guard let i = firstIndex(of: "#") else { return self }
          return String(self[..<i])
      }
    
    subscript(i: Int) -> Character {
        let idx = self.index(self.startIndex, offsetBy: i)
        return self[idx]
    }
    
    var hasNonWhitespace: Bool {
        !self.trimmed().isEmpty
    }
}

extension String {
    var voiceLength:Double {
        var res: Double = 0.0
        for c in self {
            switch c {
                case " ":
                    res += 0.01
                case ",":
                    res += 2.0
                case ".", "!", "?":
                    res += 3.0
                case "0"..."9":
                    res += 3.0
                default:
                    res += 1.0
            }
        }
        return res
    }
}

extension String {
    func buildOffsetsToIndices() -> [Int: String.Index] {
        Dictionary(uniqueKeysWithValues: indices.enumerated().map { (offset, idx) in
            (offset, idx)
        })
    }
}

public extension String {
    func padRight(_ width: Int, with char: Character = " ") -> String {
        if count >= width { return self }
        return self + String(repeating: String(char), count: width - count)
    }

    func padLeft(_ width: Int, with char: Character = " ") -> String {
        if count >= width { return self }
        return String(repeating: String(char), count: width - count) + self
    }

    func truncated(_ maxWidth: Int) -> String {
        if count <= maxWidth { return self }
        guard maxWidth > 3 else { return String(prefix(maxWidth)) }
        return String(prefix(maxWidth - 3)) + "..."
    }
}

extension Substring {
    func trim() -> String {
        return trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func collapseWhiteSpace() -> String {
        return replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

public extension String {
    func appendingPathComponent(_ component: String, delimiter: String="/") -> String {
        guard !component.isEmpty else {
            return self
        }

        guard !self.isEmpty else {
            return component
        }

        guard !delimiter.isEmpty else {
            return self + component
        }

        if delimiter.count == 1, let d = delimiter.first {
            var comp = component

            if comp.first == d {
                comp.removeFirst()
            }

            if self.last == d {
                return self + comp
            }

            return self + delimiter + comp
        }

        if self.hasSuffix(delimiter) {
            return self + component
        }

        return self + delimiter + component
    }
    func deletingLastPathComponent(delimiter: String="/") -> String {
        guard !delimiter.isEmpty else {
            return ""
        }

        let comps = self.components(separatedBy: delimiter)
        guard comps.count > 0 else {
            return ""
        }

        let trimmed = comps.dropLast()
        return trimmed.joined(separator: delimiter)
    }

    func lastPathComponent(delimiter: String = "/") -> String {
           guard !delimiter.isEmpty else {
               return ""
           }

           var s = self
           while s.hasSuffix(delimiter) {
               s.removeLast(delimiter.count)
           }

           guard !s.isEmpty else {
               return ""
           }

           let parts = s.components(separatedBy: delimiter)
           return parts.last ?? ""
    }
    
    func deletingPathExtension() -> String {
        guard let dot = lastIndex(of: ".") else { return self }
        guard let slash = lastIndex(of: "/") else {
            if dot == startIndex { return self }          // ".gitignore"
            return String(self[..<dot])                   // "file.txt" -> "file"
        }
        if dot <= index(after: slash) { return self }     // "/.gitignore" or "/foo/.bar"
        return String(self[..<dot])                       // "/path/file.txt" -> "/path/file"
    }
}

public extension String {
    var sha256:String {
        let digest = SHA256.hash(data: Data(self.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}


extension Character {
    var isDigit:Bool {
        return ("0"..."9").contains(self)
    }
}


extension [String:String] {
    var stringRepr:String {
        self.sorted(by: { $0.key < $1.key })
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: "\n")
    }
    
    var sha256:String {
        stringRepr.sha256
    }
}
