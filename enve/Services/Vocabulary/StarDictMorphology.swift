import Foundation

enum StarDictMorphology {

    private static let vowelAccentMap: [Character: Character] = [
        "á": "a", "à": "a", "â": "a", "ä": "a", "ã": "a", "å": "a",
        "é": "e", "è": "e", "ê": "e", "ë": "e",
        "í": "i", "ì": "i", "î": "i", "ï": "i",
        "ó": "o", "ò": "o", "ô": "o", "ö": "o", "õ": "o",
        "ú": "u", "ù": "u", "û": "u", "ü": "u",
        "ý": "y", "ÿ": "y",
    ]

    static func normalize(_ word: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(word.unicodeScalars.count)
        for scalar in word.lowercased().unicodeScalars {
            if let mapped = vowelAccentMap[Character(scalar)] {
                out.append(contentsOf: String(mapped).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    static func candidates(for raw: String) -> [String] {
        let w = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        var out: [String] = []

        func add(_ s: String) {
            guard s.count > 1, seen.insert(s).inserted else { return }
            out.append(s)
        }

        add(w)

        if w.hasSuffix("ily"), w.count > 4 { add(String(w.dropLast(3)) + "y") }
        if w.hasSuffix("ly"), w.count > 4 { add(String(w.dropLast(2))) }

        if w.hasSuffix("ves"), w.count > 4 {
            add(String(w.dropLast(3)) + "f")
            add(String(w.dropLast(3)) + "fe")
        }
        if w.hasSuffix("ies"), w.count > 4 { add(String(w.dropLast(3)) + "y") }

        if w.hasSuffix("ing"), w.count > 5 {
            let base = String(w.dropLast(3))
            add(base + "e")
            add(base)
            if base.count >= 2, base.last == base.dropLast().last {
                add(String(base.dropLast()))
            }
        }

        if w.hasSuffix("ied"), w.count > 4 { add(String(w.dropLast(3)) + "y") }
        if w.hasSuffix("ed"), w.count > 3 {
            let base = String(w.dropLast(2))
            add(String(w.dropLast()))
            add(base)
            if base.count >= 2, base.last == base.dropLast().last {
                add(String(base.dropLast()))
            }
        }

        if w.hasSuffix("est"), w.count > 5 {
            let base = String(w.dropLast(3))
            add(base + "e")
            add(base)
            if base.count >= 2, base.last == base.dropLast().last {
                add(String(base.dropLast()))
            }
        }
        if w.hasSuffix("er"), w.count > 4 {
            let base = String(w.dropLast(2))
            add(base + "e")
            add(base)
            if base.count >= 2, base.last == base.dropLast().last {
                add(String(base.dropLast()))
            }
        }

        if w.hasSuffix("es"), w.count > 3 {
            add(String(w.dropLast()))
            add(String(w.dropLast(2)))
        }
        if w.hasSuffix("s"), w.count > 3 {
            add(String(w.dropLast()))
        }

        if w.count >= 3 {
            add(w + "a")
            add(w + "e")
            add(w + "i")

            if w.hasSuffix("o"), w.count > 3 {
                add(String(w.dropLast()))
                add(String(w.dropLast()) + "a")
            }

            if w.hasSuffix("i"), w.count > 3 {
                add(String(w.dropLast()) + "a")
                add(String(w.dropLast()) + "e")
            }
            if w.hasSuffix("u"), w.count > 3 {
                add(String(w.dropLast()))
                add(String(w.dropLast()) + "a")
                add(String(w.dropLast()) + "e")
            }

            if w.hasSuffix("ji"), w.count > 3 { add(String(w.dropLast(2))) }
            if w.hasSuffix("evi"), w.count > 4 {
                add(String(w.dropLast(3)))
                add(String(w.dropLast(3)) + "e")
            }
            if w.hasSuffix("ovi"), w.count > 4 { add(String(w.dropLast(3))) }
            if w.hasSuffix("je"), w.count > 3 { add(String(w.dropLast(2))) }
            if w.hasSuffix("i"), w.count > 3 { add(String(w.dropLast())) }
            if w.hasSuffix("e"), w.count > 3 { add(String(w.dropLast()) + "a") }

            if w.hasSuffix("ega"), w.count > 4 { add(String(w.dropLast(3)) + "i") }
            if w.hasSuffix("emu"), w.count > 4 { add(String(w.dropLast(3)) + "i") }
            if w.hasSuffix("em"), w.count > 3 { add(String(w.dropLast(2)) + "i") }
            if w.hasSuffix("ih"), w.count > 3 { add(String(w.dropLast(2)) + "i") }

            if w.hasSuffix("ati"), w.count > 4 { add(String(w.dropLast(3))) }
            if w.hasSuffix("iti"), w.count > 4 { add(String(w.dropLast(3))) }
            if w.hasSuffix("eti"), w.count > 4 { add(String(w.dropLast(3))) }

            if w.hasSuffix("am"), w.count > 3 {
                let s = String(w.dropLast(2))
                add(s); add(s + "ti"); add(s + "ati")
            }
            if w.hasSuffix("aš"), w.count > 3 {
                let s = String(w.dropLast(2))
                add(s); add(s + "ti"); add(s + "ati")
            }
            if w.hasSuffix("iš"), w.count > 3 {
                let s = String(w.dropLast(2))
                add(s); add(s + "ti"); add(s + "iti")
            }
            if w.hasSuffix("im"), w.count > 3 {
                let s = String(w.dropLast(2))
                add(s); add(s + "ti"); add(s + "iti")
            }
            if w.hasSuffix("eš"), w.count > 3 {
                let s = String(w.dropLast(2))
                add(s); add(s + "ti"); add(s + "eti")
            }
            if w.hasSuffix("em"), w.count > 3 {
                let s = String(w.dropLast(2))
                add(s + "eti")
            }
        }

        return out
    }
}
