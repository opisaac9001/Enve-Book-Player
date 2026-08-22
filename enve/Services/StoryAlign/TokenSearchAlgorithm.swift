import Foundation
@preconcurrency import ReadiumShared

final class TokenSearchAlgorithm: StringSearchAlgorithm {
    let options: SearchOptions = .init(
        caseSensitive: false,
        diacriticSensitive: false,
        exact: false,
        regularExpression: false
    )

    private let minimumWindowLength = 160
    private let minTokenLength = 2

    init() {}

    func findRanges(
        of query: String,
        options: SearchOptions,
        in text: String,
        language: Language?
    ) async -> [Range<String.Index>] {
        var compareOptions: NSString.CompareOptions = []
        if options.regularExpression ?? false {
            compareOptions.insert(.regularExpression)
        } else if options.exact ?? false {
            compareOptions.insert(.literal)
        } else {
            if !(options.caseSensitive ?? false) {
                compareOptions.insert(.caseInsensitive)
            }
            if !(options.diacriticSensitive ?? false) {
                compareOptions.insert(.diacriticInsensitive)
            }
        }

        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }

        if tokens.count == 1 {
            return findSubstringRanges(of: tokens[0], in: text, options: compareOptions, language: language)
        }

        let perToken = tokens.map { token in
            findSubstringRanges(of: token, in: text, options: compareOptions, language: language)
        }

        guard perToken.allSatisfy({ !$0.isEmpty }) else {
            return findSubstringRanges(of: query, in: text, options: compareOptions, language: language)
        }

        return mergeTokenRanges(
            perToken: perToken,
            in: text,
            windowLength: max(minimumWindowLength, query.count + 40)
        )
    }

    private func tokenize(_ query: String) -> [String] {
        let pieces =
            query
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }

        let kept = pieces.filter { $0.count >= minTokenLength }
        return kept.isEmpty ? pieces : kept
    }

    private func findSubstringRanges(
        of needle: String,
        in text: String,
        options: NSString.CompareOptions,
        language: Language?
    ) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while !Task.isCancelled,
            index < text.endIndex,
            let range = text.range(of: needle, options: options, range: index..<text.endIndex, locale: language?.locale),
            !range.isEmpty
        {
            ranges.append(range)
            index = text.index(range.lowerBound, offsetBy: 1)
        }
        return ranges
    }

    private func mergeTokenRanges(
        perToken: [[Range<String.Index>]],
        in text: String,
        windowLength: Int
    ) -> [Range<String.Index>] {
        guard let firstTokenRanges = perToken.first else { return [] }
        var spans: [Range<String.Index>] = []
        for firstRange in firstTokenRanges {
            var upperBound = firstRange.upperBound
            var matched = true
            for tokenRanges in perToken.dropFirst() {
                guard let nextRange = tokenRanges.first(where: {
                    $0.lowerBound >= upperBound
                        && text.distance(from: firstRange.lowerBound, to: $0.upperBound) <= windowLength
                }) else {
                    matched = false
                    break
                }
                upperBound = nextRange.upperBound
            }
            if matched {
                spans.append(firstRange.lowerBound..<upperBound)
            }
        }

        guard !spans.isEmpty else { return [] }

        var collapsed: [Range<String.Index>] = []
        for span in spans {
            if let last = collapsed.last, span.lowerBound < last.upperBound {
                if span.upperBound > last.upperBound {
                    collapsed[collapsed.count - 1] = last.lowerBound..<span.upperBound
                }
            } else {
                collapsed.append(span)
            }
        }
        return collapsed
    }
}

enum TokenSearchInstaller {
    static let publicationTransform: Publication.Builder.Transform = { _, _, services in
        services.setSearchServiceFactory(
            ContentSearchService.makeFactory(searchAlgorithm: TokenSearchAlgorithm())
        )
    }
}
