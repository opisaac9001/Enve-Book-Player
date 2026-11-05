package com.enve.core.reader

data class PdfSpread(val first: Int, val last: Int) {
    val pages: IntRange get() = first..last
}

data class PdfReadingLayout(
    val twoPageView: Boolean = false,
    val showCoverSeparately: Boolean = false,
    val pageAdjust: String = "Fit",
) {
    val coverStandsAlone: Boolean get() = twoPageView && showCoverSeparately

    fun spreadContaining(page: Int, pageCount: Int): PdfSpread {
        val lastPage = (pageCount - 1).coerceAtLeast(0)
        val selected = page.coerceIn(0, lastPage)
        if (!twoPageView || pageCount <= 1) return PdfSpread(selected, selected)
        if (coverStandsAlone && selected == 0) return PdfSpread(0, 0)
        val offset = if (coverStandsAlone) 1 else 0
        val start = selected - (selected - offset) % 2
        return PdfSpread(start, (start + 1).coerceAtMost(lastPage))
    }

    fun nextSpread(current: PdfSpread, pageCount: Int): PdfSpread? =
        if (current.last >= pageCount - 1) null else spreadContaining(current.last + 1, pageCount)

    fun previousSpread(current: PdfSpread, pageCount: Int): PdfSpread? =
        if (current.first <= 0) null else spreadContaining(current.first - 1, pageCount)

    fun pageAfterTurningForward(selectedPage: Int, pageCount: Int): Int? =
        nextSpread(spreadContaining(selectedPage, pageCount), pageCount)?.last

    fun pageAfterTurningBackward(selectedPage: Int, pageCount: Int): Int? =
        previousSpread(spreadContaining(selectedPage, pageCount), pageCount)?.last
}
