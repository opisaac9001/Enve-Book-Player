import Foundation

func matchesMergeOverrides(existing: UserOverridesLayer?, new: UserOverridesLayer) -> UserOverridesLayer {
    var result = existing ?? UserOverridesLayer()
    if let v = new.customTitle { result.customTitle = v }
    if let v = new.customAuthor { result.customAuthor = v }
    if let v = new.customNarrator { result.customNarrator = v }
    if let v = new.customSeries { result.customSeries = v }
    if let v = new.customSeriesNumber { result.customSeriesNumber = v }
    if let v = new.customSeriesSequence { result.customSeriesSequence = v }
    if let v = new.customCoverPath { result.customCoverPath = v }
    if let v = new.customDescription { result.customDescription = v }
    if let v = new.customPublisher { result.customPublisher = v }
    if let v = new.customGenres { result.customGenres = v }
    return result
}

func matchesStripHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
