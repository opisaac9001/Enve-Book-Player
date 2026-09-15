package com.enve.app.ui.screens.reader

internal data class BundledReaderFontFace(
    val assetPath: String,
    val weight: Int,
    val italic: Boolean = false,
)

internal data class BundledReaderFont(
    val family: String,
    val faces: List<BundledReaderFontFace>,
    val declareInReadium: Boolean = true,
)

internal val BUNDLED_READER_FONTS = listOf(
    BundledReaderFont(
        family = "OpenDyslexic",
        faces = listOf(
            BundledReaderFontFace("readium/fonts/OpenDyslexic-Regular.otf", 400),
            BundledReaderFontFace("readium/fonts/OpenDyslexic-Regular.otf", 700),
        ),
        declareInReadium = false,
    ),
    BundledReaderFont(
        family = "Literata",
        faces = listOf(
            BundledReaderFontFace("reader-fonts/Literata.ttf", 400),
            BundledReaderFontFace("reader-fonts/Literata.ttf", 700),
            BundledReaderFontFace("reader-fonts/Literata-Italic.ttf", 400, italic = true),
            BundledReaderFontFace("reader-fonts/Literata-Italic.ttf", 700, italic = true),
        ),
    ),
    BundledReaderFont(
        family = "Atkinson Hyperlegible",
        faces = listOf(
            BundledReaderFontFace("reader-fonts/AtkinsonHyperlegible.ttf", 400),
            BundledReaderFontFace("reader-fonts/AtkinsonHyperlegible.ttf", 700),
            BundledReaderFontFace("reader-fonts/AtkinsonHyperlegible-Italic.ttf", 400, italic = true),
            BundledReaderFontFace("reader-fonts/AtkinsonHyperlegible-Italic.ttf", 700, italic = true),
        ),
    ),
    BundledReaderFont(
        family = "Lexend",
        faces = listOf(
            BundledReaderFontFace("reader-fonts/Lexend.ttf", 400),
            BundledReaderFontFace("reader-fonts/Lexend.ttf", 700),
        ),
    ),
    BundledReaderFont(
        family = "iA Writer Duo",
        faces = listOf(
            BundledReaderFontFace("readium/readium-css/fonts/iAWriterDuospace-Regular.ttf", 400),
            BundledReaderFontFace("readium/readium-css/fonts/iAWriterDuospace-Regular.ttf", 700),
        ),
        declareInReadium = false,
    ),
)
