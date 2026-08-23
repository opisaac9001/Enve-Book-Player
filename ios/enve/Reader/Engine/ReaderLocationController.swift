import Foundation
import ReadiumShared

enum ReadAloudOverlayTransform {
    static func hrefMatches(_ smilHref: String, _ readerHref: String) -> Bool {
        if smilHref == readerHref { return true }

        let smil = smilHref.hasPrefix("/") ? String(smilHref.dropFirst()) : smilHref
        let reader = readerHref.hasPrefix("/") ? String(readerHref.dropFirst()) : readerHref
        if smil == reader || smil.hasSuffix(reader) || reader.hasSuffix(smil) { return true }

        let smilFile = (smil as NSString).lastPathComponent
        let readerFile = (reader as NSString).lastPathComponent
        return !smilFile.isEmpty && smilFile == readerFile
    }

    static func normalizedDocumentHref(_ href: String?) -> String? {
        guard let href else { return nil }
        let path = href.components(separatedBy: "#").first ?? href
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    static func bestClipIndex(
        in clips: [AudioOverlayClip],
        fragmentId: String,
        preferredHref: String?
    ) -> Int? {
        let candidates = clips.indices.filter { clips[$0].fragmentId == fragmentId }
        guard !candidates.isEmpty else { return nil }
        if let preferredHref,
            let hrefMatch = candidates.first(where: { hrefMatches(clips[$0].textHref, preferredHref) })
        {
            return hrefMatch
        }
        return candidates[0]
    }
}

enum ReaderLocationController {
    static func locationsDiffer(_ initial: Locator?, _ current: Locator?) -> Bool {
        guard let initial, let current else { return false }
        let initialHref = initial.href.string.removingPercentEncoding ?? initial.href.string
        let currentHref = current.href.string.removingPercentEncoding ?? current.href.string
        if initialHref != currentHref { return true }

        let initialProgression = initial.locations.progression ?? initial.locations.totalProgression
        let currentProgression = current.locations.progression ?? current.locations.totalProgression
        if let initialProgression, let currentProgression {
            return abs(initialProgression - currentProgression) > 0.002
        }
        return false
    }

    static func strippingCFIFragments(_ locator: Locator) -> Locator {
        let fragments = locator.locations.fragments.filter { !$0.hasPrefix("epubcfi(") }
        guard fragments.count != locator.locations.fragments.count else { return locator }
        return locator.copy(locations: { $0.fragments = fragments })
    }

    static func normalizedHref(_ href: String) -> String {
        let path = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? href
        return path.removingPercentEncoding ?? path
    }

    static func retargetingHref(_ locatorJSON: String, candidateHrefs: [String]) -> String {
        guard let data = locatorJSON.data(using: .utf8),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let href = json["href"] as? String,
            let match = candidateHrefs.first(where: { ReadAloudOverlayTransform.hrefMatches(href, $0) })
        else {
            return locatorJSON
        }
        json["href"] = match
        guard let retargeted = try? JSONSerialization.data(withJSONObject: json) else {
            return locatorJSON
        }
        return String(decoding: retargeted, as: UTF8.self)
    }
}
