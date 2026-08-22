import Foundation

enum AudiobookFileGrouping {
    nonisolated static let minimumStandaloneBookSize: Int64 = 64 * 1_024 * 1_024

    nonisolated static func groups<Element>(
        _ files: [Element],
        name: (Element) -> String,
        bookEvidence: (Element) -> Bool = { _ in false },
        forcedStandalone: (Element) -> Bool = { _ in false }
    ) -> [[Element]] {
        guard files.count > 1 else { return files.isEmpty ? [] : [files] }

        let sortedFiles = sorted(files, name: name)
        let hasFilenameChapterEvidence = sortedFiles.contains {
            chapterGroupingKey(name($0)) != nil
        }
        let selfContainedExtensions: Set<String> = ["m4b", "m4a", "mp4"]
        let standaloneBooks = sortedFiles.filter {
            let filename = name($0)
            let hasChapterEvidence = chapterGroupingKey(filename) != nil
            return forcedStandalone($0)
                || isExplicitBook(filename)
                || (!hasChapterEvidence
                    && selfContainedExtensions.contains((filename as NSString).pathExtension.lowercased()))
                || (!hasFilenameChapterEvidence && bookEvidence($0))
        }
        let standaloneIds = Set(standaloneBooks.map { name($0).lowercased() })
        let candidates = sortedFiles.filter {
            !standaloneIds.contains(name($0).lowercased())
        }

        var result = standaloneBooks.map { [$0] }
        guard !candidates.isEmpty else { return result }

        let explicitKeys = Set(candidates.compactMap { chapterGroupingKey(name($0)) })
        let defaultKey = explicitKeys.count == 1 ? explicitKeys.first! : "multipart:ambiguous"
        let grouped = Dictionary(grouping: candidates) { file in
            chapterGroupingKey(name(file)) ?? defaultKey
        }
        result.append(contentsOf: grouped.values.map { group in
            sorted(group, name: name)
        })
        return result.sorted {
            guard let lhs = $0.first, let rhs = $1.first else { return !$0.isEmpty }
            return name(lhs).localizedStandardCompare(name(rhs)) == .orderedAscending
        }
    }

    nonisolated static func sorted<Element>(
        _ files: [Element],
        name: (Element) -> String
    ) -> [Element] {
        files.sorted { lhs, rhs in
            let lhsPosition = sequencePosition(name(lhs))
            let rhsPosition = sequencePosition(name(rhs))
            if lhsPosition.category != rhsPosition.category {
                return lhsPosition.category < rhsPosition.category
            }
            if lhsPosition.number != rhsPosition.number {
                return lhsPosition.number < rhsPosition.number
            }
            return name(lhs).localizedStandardCompare(name(rhs)) == .orderedAscending
        }
    }

    nonisolated private static func chapterGroupingKey(_ filename: String) -> String? {
        if let prefix = chapterSequencePrefix(filename) {
            return prefix.isEmpty
                ? "multipart:chapter-sequence"
                : "multipart:chapter-sequence:\(prefix)"
        }
        if isLeadingTrackNumber(filename) {
            return "multipart:chapter-sequence"
        }
        return multipartStem(filename).map { "multipart:\($0)" }
    }

    nonisolated static func inferredTitle(for filename: String) -> String {
        let filenameStem = (filename as NSString).deletingPathExtension
        guard multipartStem(filename) != nil else { return filenameStem }

        let title = filenameStem.replacingOccurrences(
            of: #"(?i)[\s._-]+(?:(?:part|track|chapter|disc|cd)[\s._-]*)?\d+$"#,
            with: "",
            options: .regularExpression
        )
        return title.isEmpty ? filenameStem : title
    }

    nonisolated private static func multipartStem(_ filename: String) -> String? {
        var normalized = (filename as NSString).deletingPathExtension.lowercased()
        for word in ["unabridged", "audiobook", "audio book"] {
            normalized = normalized.replacingOccurrences(of: word, with: " ")
        }
        normalized = normalized.replacingOccurrences(
            of: #"[\W_]+"#,
            with: " ",
            options: .regularExpression
        )
        let tokens = normalized.split(separator: " ").map(String.init)
        let explicitPartMarkers = ["part", "track", "chapter", "disc", "cd"]
        let hasPartMarker = tokens.dropLast().last.map(explicitPartMarkers.contains) == true
        guard let number = tokens.last,
            number.allSatisfy(\.isNumber),
            number.count >= 2 || hasPartMarker
        else {
            return nil
        }
        let stem = tokens.dropLast().joined(separator: " ")
        return stem.isEmpty ? nil : stem
    }

    nonisolated private static func chapterSequencePrefix(_ filename: String) -> String? {
        let stem = (filename as NSString).deletingPathExtension
        guard let range = stem.range(
            of: #"\b(?:chapter|track|part|disc|cd)[\s._#-]*\d+\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        return normalizedTitle(String(stem[..<range.lowerBound]))
    }

    nonisolated private static func isLeadingTrackNumber(_ filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension
        return stem.range(of: #"^\s*\d+\b"#, options: .regularExpression) != nil
    }

    nonisolated private static func isExplicitBook(_ filename: String) -> Bool {
        guard chapterSequencePrefix(filename) == nil, !isLeadingTrackNumber(filename) else {
            return false
        }
        let stem = (filename as NSString).deletingPathExtension
        return stem.range(
            of: #"\b(?:book|volume|vol)[\s._#-]*\d+\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    nonisolated private static func sequencePosition(_ filename: String) -> (category: Int, number: Int) {
        let normalized = normalizedTitle(filename)
        if ["opening credits", "intro", "introduction", "prologue"].contains(normalized) {
            return (0, 0)
        }
        if let chapterNumber = firstMatch(
            in: (filename as NSString).deletingPathExtension,
            pattern: #"^\s*chapter[\s._-]*(\d+)\b"#
        ) {
            return (1, chapterNumber)
        }
        if ["credits", "closing credits", "end credits", "epilogue"].contains(normalized) {
            return (3, 0)
        }
        return (2, 0)
    }

    nonisolated private static func normalizedTitle(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
            .lowercased()
            .replacingOccurrences(of: #"[\W_]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func firstMatch(in value: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
            ),
            let range = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return Int(value[range])
    }
}
