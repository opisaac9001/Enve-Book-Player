import Foundation

// Family names and categories verified against https://fonts.google.com/metadata/fonts (2026-11-14).
enum ReaderFontCatalog {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case serif
        case sansSerif
        case monospace

        var id: String { rawValue }

        var label: String {
            switch self {
            case .serif: "Serif"
            case .sansSerif: "Sans serif"
            case .monospace: "Monospace"
            }
        }
    }

    struct Family: Identifiable, Hashable, Sendable {
        let name: String
        let category: Category

        var id: String { name }
    }

    static func families(matching query: String, in category: Category?) -> [Family] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return families.filter { family in
            (category == nil || family.category == category)
                && (trimmed.isEmpty || family.name.localizedStandardContains(trimmed))
        }
    }

    static func family(named name: String) -> Family? {
        families.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static let families: [Family] =
        serif.map { Family(name: $0, category: .serif) }
        + sansSerif.map { Family(name: $0, category: .sansSerif) }
        + monospace.map { Family(name: $0, category: .monospace) }

    private static let serif = [
        "Abhaya Libre", "Adamina", "Alegreya", "Alike", "Amethysta", "Amiri", "Andada Pro", "Arbutus Slab",
        "Arvo", "Average", "Besley", "Bitter", "Bodoni Moda", "Brawler", "Bree Serif", "Brygada 1918",
        "Cambo", "Cardo", "Castoro", "Charis SIL", "Cinzel", "Cormorant", "Cormorant Garamond", "Coustard",
        "Crete Round", "Crimson Pro", "Crimson Text", "DM Serif Display", "DM Serif Text", "Domine",
        "EB Garamond", "Fanwood Text", "Faustina", "Frank Ruhl Libre", "Fraunces", "Gelasio",
        "Gentium Book Plus", "Gentium Plus", "Gloock", "Goudy Bookletter 1911", "Halant", "Holtwood One SC",
        "IBM Plex Serif", "IM Fell English", "Instrument Serif", "Josefin Slab", "Junge", "Kreon",
        "Libre Baskerville", "Libre Bodoni", "Libre Caslon Display", "Libre Caslon Text", "Linden Hill",
        "Literata", "Lora", "Lusitana", "Lustria", "Marcellus", "Martel", "Mate", "Merriweather", "Neuton",
        "Newsreader", "Noticia Text", "Noto Serif", "Old Standard TT", "Ovo", "PT Serif", "Petrona",
        "Piazzolla", "Playfair", "Playfair Display", "Playfair Display SC", "Prata", "Quattrocento", "Radley",
        "Rasa", "Roboto Slab", "Rokkitt", "Rufina", "Sorts Mill Goudy", "Source Serif 4", "Spectral", "Tinos",
        "Trirong", "Ultra", "Unna", "Vidaloka", "Vollkorn", "Young Serif", "Yrsa", "Zilla Slab",
    ]

    private static let sansSerif = [
        "Albert Sans", "Alegreya Sans", "Andika", "Anton", "Archivo", "Archivo Black", "Arimo", "Asap",
        "Assistant", "Atkinson Hyperlegible", "Atkinson Hyperlegible Next", "Barlow", "Be Vietnam Pro",
        "Bebas Neue", "Cabin", "Cantarell", "Carlito", "Commissioner", "DM Sans", "Didact Gothic",
        "Encode Sans", "Exo 2", "Federo", "Figtree", "Fira Sans", "Fjalla One", "Fredoka", "Geist",
        "Golos Text", "Gothic A1", "Gudea", "Hanken Grotesk", "Heebo", "Hind", "IBM Plex Sans",
        "Instrument Sans", "Inter", "Istok Web", "Josefin Sans", "Jost", "Karla", "Kumbh Sans", "Lato",
        "Lexend", "Lexend Deca", "Libre Franklin", "Manrope", "Maven Pro", "Mona Sans", "Montserrat", "Mukta",
        "Mulish", "Noto Sans", "Noto Sans Mono", "Nunito", "Nunito Sans", "Onest", "Open Sans", "Orbitron",
        "Oswald", "Outfit", "Overpass", "Oxygen", "PT Sans", "Paytone One", "Plus Jakarta Sans", "Poppins",
        "Proza Libre", "Public Sans", "Questrial", "Quicksand", "Radio Canada", "Raleway", "Readex Pro",
        "Red Hat Display", "Red Hat Text", "Roboto", "Rosario", "Rubik", "Russo One", "Sansita",
        "Schibsted Grotesk", "Signika", "Sora", "Source Sans 3", "Space Grotesk", "Titillium Web", "Ubuntu",
        "Ubuntu Sans", "Urbanist", "Varela Round", "Wix Madefor Text", "Work Sans", "Ysabeau",
    ]

    private static let monospace = [
        "Anonymous Pro", "Azeret Mono", "Chivo Mono", "Courier Prime", "Cousine", "Cutive Mono", "DM Mono",
        "Fira Code", "Fira Mono", "Geist Mono", "IBM Plex Mono", "Inconsolata", "JetBrains Mono",
        "Major Mono Display", "Martian Mono", "Overpass Mono", "PT Mono", "Red Hat Mono", "Roboto Mono",
        "Share Tech Mono", "Sometype Mono", "Source Code Pro", "Space Mono", "Spline Sans Mono", "Ubuntu Mono",
        "Victor Mono", "Xanh Mono",
    ]
}
