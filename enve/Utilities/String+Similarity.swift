import Foundation

extension String {

    func levenshteinDistance(to target: String) -> Int {
        let s = Array(self)
        let t = Array(target)
        let sCount = s.count
        let tCount = t.count

        if sCount == 0 { return tCount }
        if tCount == 0 { return sCount }

        var previousRow = Array(0...tCount)
        var currentRow = [Int](repeating: 0, count: tCount + 1)

        for i in 1...sCount {
            currentRow[0] = i
            for j in 1...tCount {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                currentRow[j] = Swift.min(
                    previousRow[j] + 1,
                    currentRow[j - 1] + 1,
                    previousRow[j - 1] + cost
                )
            }
            previousRow = currentRow
        }

        return previousRow[tCount]
    }

    func similarity(to target: String) -> Double {
        if self == target { return 1.0 }

        let maxLength = Double(max(self.count, target.count))
        if maxLength == 0 { return 1.0 }

        let distance = Double(levenshteinDistance(to: target))
        return 1.0 - (distance / maxLength)
    }

    var normalizedForMatching: String {
        let allowed = CharacterSet.alphanumerics
        return self.lowercased()
            .components(separatedBy: allowed.inverted)
            .joined()
    }

    var cleanedTitle: String {
        var str = self
        if let idx = str.firstIndex(of: "(") {
            str = String(str[..<idx])
        }
        if let idx = str.firstIndex(of: "[") {
            str = String(str[..<idx])
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
